// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQL
import WinMDSynthesis
import WinMD

struct ShellTests {
  @Test("each meta-command answers to its `.`-prefixed spelling")
  func spellings() {
    // The leading-token dispatch matches a `.`-token against each `Metacommand`
    // type's `spelling`; these are the tokens `execute` routes on.
    #expect(Tables.spelling == ".tables")
    #expect(Help.spelling == ".help")
    #expect(Quit.spelling == ".quit")
    #expect(Read.spelling == ".read")
    #expect(Render.spelling == ".render")
  }

  @Test("`.read` parses its trailing path, trimming surrounding whitespace")
  func read() {
    // `Read.init` takes the rest of the statement after the spelling token and
    // trims it to the path; the stream has already split off `.read`.
    #expect(Read(" foo.sql").path == "foo.sql")
    #expect(Read("  spaced.sql ").path == "spaced.sql")
    // No argument leaves an empty path — `execute` rejects it as unknown.
    #expect(Read("").path.isEmpty)
  }

  @Test("`.render` parses its interface and template arguments")
  func render() {
    // `Render.init` splits the rest of the statement into interface then
    // template; both are required, so anything but two fields leaves them empty
    // and `execute` rejects it.
    let render = Render(" IFoo com ")
    #expect(render.interface == "IFoo")
    #expect(render.template == "com")
    #expect(Render("IFoo").interface.isEmpty)
    #expect(Render("").template.isEmpty)
  }

  @Test("a `;`-separated script streams into trimmed, non-empty statements")
  func stream() {
    // The `Statements` stream is the load-bearing part of a batch run: trailing
    // `;`, whitespace, and blank statements (a `;;`) are dropped, each statement
    // trimmed, and a `.`-meta line yields whole.
    let script = """
      CREATE VIEW a AS SELECT 1;
        SELECT 2 ;
      ;
      .tables
      """
    #expect(Array(Statements(of: script))
            == ["CREATE VIEW a AS SELECT 1", "SELECT 2", ".tables"])
    #expect(Array(Statements(of: "")).isEmpty)
    #expect(Array(Statements(of: "   \n  ")).isEmpty)
  }

  @Test("the statement stream accumulates a SQL statement across lines")
  func streamMultiline() {
    // A SQL statement may span lines, accumulating until a `;` closes it; an
    // unterminated trailing statement still yields at end of input — the
    // closing `;` is optional, so a one-shot query keeps its last statement.
    let script = """
      SELECT 1,
             2;
      SELECT 3
      """
    #expect(Array(Statements(of: script))
            == ["SELECT 1,\n       2", "SELECT 3"])
  }

  @Test("a `;` inside a string literal does not terminate the statement")
  func streamStringLiteral() {
    // The splitter must not cut a statement at a `;` that lives inside a
    // single-quoted literal — that `;` is data the SQL lexer scans, not a
    // terminator. A doubled `''` is an escaped quote, so it stays in the
    // literal; the run keeps streaming across an unterminated literal until it
    // closes. Otherwise the splitter rejects queries the parser handles.
    #expect(Array(Statements(of: "SELECT ';' AS s FROM TypeDef;"))
            == ["SELECT ';' AS s FROM TypeDef"])
    #expect(Array(Statements(of: "SELECT ';a' AS a; SELECT 2;"))
            == ["SELECT ';a' AS a", "SELECT 2"])
    #expect(Array(Statements(of: "SELECT 'a;''b;' AS s;"))
            == ["SELECT 'a;''b;' AS s"])
    #expect(Array(Statements(of: "SELECT 'x;\n y;' AS s;"))
            == ["SELECT 'x;\n y;' AS s"])
  }

  @Test("a whitespace-only spacer line before a `.`-command is dropped")
  func streamSpacerBeforeMeta() {
    // A blank line carrying spaces before a meta-command must not glue onto it:
    // a whitespace-only `pending` counts as nothing, so the `.`-line still
    // yields whole and a following statement stays a separate statement —
    // otherwise the meta-command swallows the SQL as its arguments.
    #expect(Array(Statements(of: "SELECT 1;\n   \n.tables\nSELECT 2;"))
            == ["SELECT 1", ".tables", "SELECT 2"])
  }

  @Test("the bundled views are the four COM-interface views")
  func bundled() {
    // The parse-and-register path a `CREATE VIEW` reuses; the four bundled
    // views register under their case-folded names.
    let views = Session.bundled()
    #expect(Set(views.keys) == ["interfaces", "methods", "params", "bases"])
  }

  @Test("a streamed CREATE VIEW statement parses and registers a view")
  func register() throws {
    // A batch run runs each streamed statement through `execute`, whose `CREATE
    // VIEW` branch parses and registers it. A `Database` (a full PE image) is
    // awkward to assemble in memory — the WinMD fixtures all work over
    // `Storage`, not `Database` — so the end-to-end file run is not exercised
    // here. The file IO + stream is covered by `stream`, and this asserts a
    // statement a batch would yield parses to a `CREATE VIEW` and registers,
    // the exact work `execute` performs for that branch.
    var views = Dictionary<String, View>()
    for sql in Statements(of: "CREATE VIEW v AS SELECT TypeName FROM TypeDef;") {
      guard case let .create(name, view) = try Statement(parsing: sql) else {
        Issue.record("not a CREATE VIEW")
        return
      }
      views[name.lowercased()] = view
    }
    #expect(views.keys.contains("v"))
  }

  @Test("a language spec parses its escape, void, root, keyword, and type keys")
  func languageParses() {
    let swift = Language(parsing: """
      # a comment
      escape-prefix `
      escape-suffix `
      void Void
      root IUnknown
      keyword class
      keyword in

      keyword default
      type i4 CInt
      type string HSTRING
      pointer-mutable UnsafeMutablePointer
      generic-open <
      generic-close >
      opaque UnsafeMutableRawPointer
      wellknown Windows.Win32.Foundation.HRESULT HRESULT
      """)
    // A keyword identifier is wrapped in the escape delimiters; the match is
    // exact, so a name merely containing a keyword is spelled verbatim.
    #expect(swift.escape("class") == "`class`")
    #expect(swift.escape("in") == "`in`")
    #expect(swift.escape("classname") == "classname")
    #expect(swift.escape("MyMethod") == "MyMethod")
    // A value-carrying return passes through; the `void` spelling is `nil`.
    #expect(swift.returned("CInt") == "CInt")
    #expect(swift.returned("Void") == nil)
    #expect(swift.returned("") == nil)
    // The COM root is the parsed default base.
    #expect(swift.root == "IUnknown")
    // The type keys feed the `Dialect`: a couple of primitives, the pointer
    // family, and the well-known projection map through.
    let dialect = swift.dialect
    #expect(SignatureType.primitive(.int4)
                .decode(with: Resolver([:]), dialect: dialect) == "CInt")
    #expect(SignatureType.pointer(.primitive(.int4))
                .decode(with: Resolver([:]), dialect: dialect)
                == "UnsafeMutablePointer<CInt>")
    let hresult = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      hresult.rawValue: Identity(namespace: "Windows.Win32.Foundation",
                                 name: "HRESULT"),
    ])
    #expect(SignatureType.named(kind: .value, hresult)
                .decode(with: resolver, dialect: dialect) == "HRESULT")
  }

  @Test("the identity spec escapes nothing and applies no conventions")
  func languageIdentity() {
    // A template that declares no language (or names a spec with no resource)
    // gets the identity `Language`: every identifier and return is verbatim, no
    // root default applies, and its `Dialect` falls a primitive back to its
    // neutral name (empty maps ⇒ no crash).
    let identity = Language()
    #expect(identity.escape("class") == "class")
    #expect(identity.returned("Void") == "Void")
    #expect(identity.root.isEmpty)
    #expect(SignatureType.primitive(.int4)
                .decode(with: Resolver([:]), dialect: identity.dialect) == "i4")
  }
}
