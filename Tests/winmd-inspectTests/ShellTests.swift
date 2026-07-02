// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import ArgumentParser
import SQL
import WinMDSynthesis
import WinMD

import class Foundation.FileManager
import struct Foundation.Data
import struct Foundation.UUID

struct ShellTests {
  /// Runs `body` with the path of a fresh, empty regular file that exists for
  /// the call and is removed after. The root's `validate` (run on every parse)
  /// requires the database to be an existing regular file, so a parse test
  /// binds a real path rather than a made-up one.
  private static func withDatabase(_ body: (String) throws -> Void) rethrows {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? manager.createDirectory(at: directory,
                                 withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.winmd")
    manager.createFile(atPath: url.path, contents: Data())
    try body(url.path)
  }

  @Test("`query` is the default subcommand; its verb may be omitted")
  func queryIsDefault() throws {
    try ShellTests.withDatabase { database in
      // With `query` the default subcommand, `<db>` alone parses to a `Query`
      // opening the shell (no script), the same as `<db> query`, and a bare
      // `<db> <sql>` binds the trailing positional to `sql` without the verb.
      let shell =
          try #require(try Inspect.parseAsRoot([database])
                           as? winmd_inspect.Query)
      #expect(shell.sql == nil)
      #expect(shell.options.database.url.lastPathComponent == "fixture.winmd")

      let scripted =
          try #require(try Inspect.parseAsRoot([database, "SELECT 1"])
                           as? winmd_inspect.Query)
      #expect(scripted.sql == "SELECT 1")

      // A named subcommand still routes to its own command, not the default.
      let dumped = try #require(try Inspect.parseAsRoot([database, "dump"])
                                    as? Dump)
      #expect(dumped.options.database.url.lastPathComponent == "fixture.winmd")
    }
  }

  @Test("each meta-command answers to its `.`-prefixed spelling")
  func spellings() {
    // The leading-token dispatch matches a `.`-token against each `Metacommand`
    // type's `spelling`; these are the tokens `execute` routes on.
    #expect(Tables.spelling == ".tables")
    #expect(Help.spelling == ".help")
    #expect(Quit.spelling == ".quit")
    #expect(Read.spelling == ".read")
    #expect(Render.spelling == ".render")
    #expect(Bind.spelling == ".bind")
    #expect(Template.spelling == ".template")
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

  @Test("`.bind` parses its name and types its value")
  func bind() {
    // `Bind.init` takes the name (the first whitespace token) and the trimmed
    // remainder as the value, typed: an `Int`-parsable value is an `.integer`,
    // else `.text` with a surrounding single-quote pair stripped and a doubled
    // `''` unescaped to one `'`.
    #expect(Bind(" n 42").name == "n")
    #expect(Bind(" n 42").value == .integer(42))
    #expect(Bind(" s hello").value == .text("hello"))
    #expect(Bind(" s 'hello world' ").value == .text("hello world"))
    // A quoted numeral stays text — the quotes force the `.text` reading over
    // the `Int` parse.
    #expect(Bind("s '42'").value == .text("42"))
    // A doubled `''` inside the quotes is one literal `'`, so the advertised
    // single-quoted form binds an apostrophe rather than storing two quotes —
    // otherwise `WHERE Name = :name` never matches a row holding `O'Hare`.
    #expect(Bind("s 'O''Hare'").value == .text("O'Hare"))
    // A name with no value clears the binding — `value` is nil.
    #expect(Bind(" n").name == "n")
    #expect(Bind(" n").value == nil)
    #expect(Bind("  ").name.isEmpty)
  }

  @Test("`.template` parses its name and unquotes the single-quoted body")
  func template() {
    // `Template.init` takes the name (the first whitespace token) then the
    // single-quoted literal that follows, from its first `'` to the matching
    // close, `''` unescaped to one `'`.
    let simple = Template("t 'hello'")
    #expect(simple.name == "t")
    #expect(simple.body == "hello")
    // A `''` inside the body round-trips to one `'`.
    #expect(Template("t 'it''s'").body == "it's")
    // The body is data: `.end`, `;`, `{{…}}`, and `\"` are all verbatim.
    #expect(Template("t '.end; {{x}} \"q\"'").body == ".end; {{x}} \"q\"")
    // A multiline literal keeps its newlines; the stream has already handed the
    // whole block over as one statement.
    #expect(Template("t 'a\nb'").body == "a\nb")
    // A name with no quoted literal leaves an empty body.
    #expect(Template("t").name == "t")
    #expect(Template("t").body.isEmpty)
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

  @Test("an open-quote `.`-meta accumulates raw lines into one statement")
  func streamOpenQuoteMeta() {
    // A `.`-meta whose single-quoted string is still open is a multiline meta:
    // the stream accumulates raw lines verbatim (joined with `\n`) until the
    // quote closes, then yields the whole block as ONE statement — the inline
    // `.template <name> '<body>'` shape. Because the body is quote-delimited
    // DATA, a `.end` line and a `;` INSIDE it do NOT terminate the block (no
    // sentinel collision), and the following `SELECT 1;` stays a separate
    // statement. A `''` in the body is left verbatim in the meta (the command's
    // `init` unescapes it), so the whole literal round-trips.
    let script = """
      .template t '{{! language: swift }}
      protocol {{name}} {
      .end is data; not a terminator; it''s fine
      }'
      SELECT 1;
      """
    let statements = Array(Statements(of: script))
    #expect(statements.count == 2)
    #expect(statements[0] == """
      .template t '{{! language: swift }}
      protocol {{name}} {
      .end is data; not a terminator; it''s fine
      }'
      """)
    #expect(statements[1] == "SELECT 1")
  }

  @Test("an open-quote meta with a trailing-line close still yields one block")
  func streamOpenQuoteReading() {
    // Fed line-by-line (the interactive/`reading:` path), the same accumulation
    // holds: the closing `'` arriving on its own trailing line still yields the
    // whole `.template` block as one statement, and the following `SELECT 1`
    // stays separate. End-of-input flushes even without the trailing statement.
    var lines = ["  .template t 'first", "  ; second", "third'",
                 "SELECT 1"].makeIterator()
    let statements = Array(Statements(reading: { lines.next() }))
    #expect(statements.count == 2)
    #expect(statements[0] == ".template t 'first\n  ; second\nthird'")
    #expect(statements[1] == "SELECT 1")
  }

  @Test("an unclosed open-quote meta flushes at end of input")
  func streamOpenQuoteUnterminated() {
    // End of input before the quote closes flushes what was captured — the
    // closing `'` is as optional as a trailing `;`.
    #expect(Array(Statements(of: ".template t 'unterminated\nbody"))
            == [".template t 'unterminated\nbody"])
  }

  @Test("only `.template` accumulates on an open quote; other metas yield whole")
  func streamOpenQuoteTemplateOnly() {
    // The open-quote accumulation is `.template`'s alone. An apostrophe in
    // another meta-command's argument — the path in `.read /tmp/O'Brien.sql` —
    // is data, not an unterminated literal: the `.read` yields whole and the
    // following statement stays separate, rather than being swallowed as more
    // of the path.
    #expect(Array(Statements(of: ".read /tmp/O'Brien.sql\nSELECT 1;"))
            == [".read /tmp/O'Brien.sql", "SELECT 1"])
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

  @Test("the reading stream prompts primary then continuation while pending")
  func promptAccumulates() {
    // The interactive shell's prompt hook is called before each line read, told
    // whether a statement is pending (mid-accumulation, unterminated). A fresh
    // statement asks for the primary prompt (`false`); an unterminated one asks
    // for the continuation (`true`) — the cue that the shell still awaits the
    // `;`. Here a two-line statement (no `;` on the first line) prompts primary
    // before its first line, continuation before its second (the statement is
    // pending), then — once the `;` yields it and clears `pending` — primary
    // again before the end-of-input read that ends the stream.
    var script = ["SELECT 1", "FROM Module;"].makeIterator()
    var pending = Array<Bool>()
    let statements =
        Statements(reading: { script.next() },
                   prompt: { pending.append($0) })
    #expect(Array(statements) == ["SELECT 1\nFROM Module"])
    #expect(pending == [false, true, false])
  }

  @Test("a fresh statement each line prompts primary, never continuation")
  func promptFresh() {
    // Each self-terminating statement (its own `;`) leaves nothing pending, so
    // every prompt before a read is the primary — a `.`-meta line likewise. The
    // final read past the last line sees nothing pending too.
    var script = ["SELECT 1;", ".tables", "SELECT 2;"].makeIterator()
    var pending = Array<Bool>()
    let statements =
        Statements(reading: { script.next() },
                   prompt: { pending.append($0) })
    #expect(Array(statements) == ["SELECT 1", ".tables", "SELECT 2"])
    #expect(pending.allSatisfy { $0 == false })
  }

  @Test("the batch stream carries no prompt hook and never prompts")
  func batchIsQuiet() {
    // `Statements(of:)` is the argument/`.read` path; it takes no prompt hook,
    // so a batch run never prompts. Draining a multi-statement script drives
    // the same accumulation the interactive stream does, with no prompt to
    // observe — the assertion is that it streams correctly with no hook at all.
    #expect(Array(Statements(of: "SELECT 1\nFROM Module;\nSELECT 2"))
            == ["SELECT 1\nFROM Module", "SELECT 2"])
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
