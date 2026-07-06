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

  @Test func `query is the default subcommand; its verb may be omitted`() throws {
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

  @Test func `each meta-command answers to its .-prefixed spelling`() {
    // The leading-token dispatch matches a `.`-token against each `Metacommand`
    // type's `spelling`; these are the tokens `execute` routes on.
    #expect(Tables.spelling == ".tables")
    #expect(Schema.spelling == ".schema")
    #expect(Help.spelling == ".help")
    #expect(Quit.spelling == ".quit")
    #expect(Read.spelling == ".read")
    #expect(Render.spelling == ".render")
    #expect(Bind.spelling == ".bind")
    #expect(Template.spelling == ".template")
  }

  @Test func `.read parses its trailing path, trimming surrounding whitespace`() {
    // `Read.init` takes the rest of the statement after the spelling token and
    // trims it to the path; the stream has already split off `.read`.
    #expect(Read(" foo.sql").path == "foo.sql")
    #expect(Read("  spaced.sql ").path == "spaced.sql")
    // No argument leaves an empty path — `execute` rejects it as unknown.
    #expect(Read("").path.isEmpty)
  }

  @Test func `.schema parses its trailing query, dropping a trailing ;`() {
    // `Schema.init` takes the rest of the statement after the spelling token as
    // the query text, trimmed and with a single trailing `;` removed (the same
    // optional terminator a run tolerates).
    #expect(Schema(" SELECT 1").query == "SELECT 1")
    #expect(Schema("  SELECT 1 ; ").query == "SELECT 1")
    // No query leaves an empty string — `execute` rejects it as unknown.
    #expect(Schema("").query.isEmpty)
  }

  @Test func `a blank parameter local avoids colliding with a real name`() {
    // A generic method with an unnamed parameter followed by a real parameter
    // named like the synthetic local (`Foo(_ : T, _ arg0: T)`) must not emit
    // two `arg0` locals — the wrapper's forwarding method would not compile.
    // The synthetic name is chosen AFTER the real names are known, skipping any
    // `arg<N>` a real (or earlier synthetic) parameter already uses: the blank
    // takes `arg1`, the real `arg0` keeps its own name.
    let collision = Shell.parameters(["", "arg0"], types: ["T", "T"])
    #expect(collision.map { $0["local"] as? String } == ["arg1", "arg0"])
    // The blank's `name` stays empty (the protocol requirement spells `_ : T`),
    // only its `local` is synthesised.
    #expect(collision.map { $0["name"] as? String } == ["", "arg0"])
    // Two blanks number sequentially and skip a real `arg1` between them.
    let mixed = Shell.parameters(["", "arg1", ""], types: ["A", "B", "C"])
    #expect(mixed.map { $0["local"] as? String } == ["arg0", "arg1", "arg2"])
    // The last entry carries the `last` flag; the rest do not.
    #expect(mixed.map { $0["last"] as? Bool } == [false, false, true])
    // A named-only list keeps each name as its own local, no synthesis.
    let named = Shell.parameters(["a", "b"], types: ["X", "Y"])
    #expect(named.map { $0["local"] as? String } == ["a", "b"])
    // An empty list produces no entries (and sets no `last`).
    #expect(Shell.parameters([], types: []).isEmpty)
  }

  @Test func `.render parses its interface and template arguments`() {
    // `Render.init` splits the rest of the statement into interface then
    // template; both are required, so anything but two fields leaves them empty
    // and `execute` rejects it.
    let render = Render(" IFoo com ")
    #expect(render.interface == "IFoo")
    #expect(render.template == "com")
    #expect(Render("IFoo").interface.isEmpty)
    #expect(Render("").template.isEmpty)
  }

  @Test func `.bind parses its name and types its value`() {
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

  @Test func `.template parses its name and unquotes the single-quoted body`() {
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

  @Test func `a ;-separated script streams into trimmed, non-empty statements`() {
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

  @Test func `the statement stream accumulates a SQL statement across lines`() {
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

  @Test func `a ; inside a string literal does not terminate the statement`() {
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

  @Test func `a ; inside a comment does not terminate the statement`() {
    // Now that the lexer skips comments, the splitter must too: a `;` inside a
    // `--` line comment or a `/* … */` block comment is not a terminator, or a
    // valid script would be cut mid-comment before the lexer could skip it.
    #expect(Array(Statements(of: "SELECT 1 -- ; note\n; SELECT 2;"))
            == ["SELECT 1 -- ; note", "SELECT 2"])
    #expect(Array(Statements(of: "SELECT /* ; */ 1;"))
            == ["SELECT /* ; */ 1"])
    #expect(Array(Statements(of: "SELECT /* a;\n b; */ 1; SELECT 2;"))
            == ["SELECT /* a;\n b; */ 1", "SELECT 2"])
    // A `--` comment stops at its newline, so the following statement still
    // terminates rather than being swallowed by the comment; the comment text
    // simply travels with that statement (the lexer skips it at parse).
    #expect(Array(Statements(of: "SELECT 1; -- trailing\nSELECT 2;"))
            == ["SELECT 1", "-- trailing\nSELECT 2"])
  }

  @Test func `a trivia-only fragment is not yielded as a statement`() {
    // A chunk that is only whitespace and comments carries no statement, so it
    // is dropped rather than handed to the parser as empty input — a trailing
    // or standalone comment, or a comment between terminators.
    #expect(Array(Statements(of: "SELECT 1; -- trailing")) == ["SELECT 1"])
    #expect(Array(Statements(of: "-- just a comment")).isEmpty)
    #expect(Array(Statements(of: "/* a block */")).isEmpty)
    #expect(Array(Statements(of: "SELECT 1; -- note\n; SELECT 2;"))
            == ["SELECT 1", "SELECT 2"])
  }

  @Test func `an unterminated block comment is yielded, not dropped`() {
    // A CLOSED comment is trivia, but an unclosed `/*` is not: the fragment
    // must reach the parser so the lexer's unterminated-block-comment error
    // surfaces on a batch/`.read`/EOF path rather than being silently
    // swallowed.
    #expect(Array(Statements(of: "/* missing close")) == ["/* missing close"])
    #expect(Array(Statements(of: "SELECT 1; /* missing close"))
            == ["SELECT 1", "/* missing close"])
  }

  @Test func `a ; or comment inside a delimited identifier is data`() {
    // A double-quoted delimited identifier is tracked like a string literal, so
    // `--`, `/* */`, and `;` inside `"…"` are data — not a comment or a
    // terminator — and the real terminator after it is still found.
    #expect(Array(Statements(of: "SELECT \"--\" AS c;"))
            == ["SELECT \"--\" AS c"])
    #expect(Array(Statements(of: "SELECT \"a;b\" AS c;"))
            == ["SELECT \"a;b\" AS c"])
    #expect(Array(Statements(of: "SELECT \"/* x */\" AS c;"))
            == ["SELECT \"/* x */\" AS c"])
  }

  @Test func `a comment before a meta-command does not turn it into SQL`() {
    // A comment-only pending is trivia, so a following `.`-meta line is still
    // recognised as a meta-command rather than glued onto the comment and sent
    // through SQL parsing.
    #expect(Array(Statements(of: "-- note\n.tables")) == [".tables"])
    #expect(Array(Statements(of: "/* note */\n.read a.sql")) == [".read a.sql"])
  }

  @Test func `an open-quote .-meta accumulates raw lines into one statement`() {
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

  @Test func `an open-quote meta with a trailing-line close still yields one block`() {
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

  @Test func `a .template name starting with -- still accumulates its body`() {
    // The `.template` name is the first token; when it starts with `--`, the
    // meta accumulation must NOT treat the rest of the line as a comment (it is
    // meta text, not SQL) — the open single quote still opens a multiline body.
    let script = """
      .template --swift 'line one
      line two'
      SELECT 1;
      """
    let statements = Array(Statements(of: script))
    #expect(statements.count == 2)
    #expect(statements[0] == ".template --swift 'line one\nline two'")
    #expect(statements[1] == "SELECT 1")
  }

  @Test func `an unclosed open-quote meta flushes at end of input`() {
    // End of input before the quote closes flushes what was captured — the
    // closing `'` is as optional as a trailing `;`.
    #expect(Array(Statements(of: ".template t 'unterminated\nbody"))
            == [".template t 'unterminated\nbody"])
  }

  @Test func `only .template accumulates on an open quote; other metas yield whole`() {
    // The open-quote accumulation is `.template`'s alone. An apostrophe in
    // another meta-command's argument — the path in `.read /tmp/O'Brien.sql` —
    // is data, not an unterminated literal: the `.read` yields whole and the
    // following statement stays separate, rather than being swallowed as more
    // of the path.
    #expect(Array(Statements(of: ".read /tmp/O'Brien.sql\nSELECT 1;"))
            == [".read /tmp/O'Brien.sql", "SELECT 1"])
  }

  @Test func `a whitespace-only spacer line before a .-command is dropped`() {
    // A blank line carrying spaces before a meta-command must not glue onto it:
    // a whitespace-only `pending` counts as nothing, so the `.`-line still
    // yields whole and a following statement stays a separate statement —
    // otherwise the meta-command swallows the SQL as its arguments.
    #expect(Array(Statements(of: "SELECT 1;\n   \n.tables\nSELECT 2;"))
            == ["SELECT 1", ".tables", "SELECT 2"])
  }

  @Test func `the reading stream prompts primary then continuation while pending`() {
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

  @Test func `a fresh statement each line prompts primary, never continuation`() {
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

  @Test func `the batch stream carries no prompt hook and never prompts`() {
    // `Statements(of:)` is the argument/`.read` path; it takes no prompt hook,
    // so a batch run never prompts. Draining a multi-statement script drives
    // the same accumulation the interactive stream does, with no prompt to
    // observe — the assertion is that it streams correctly with no hook at all.
    #expect(Array(Statements(of: "SELECT 1\nFROM Module;\nSELECT 2"))
            == ["SELECT 1\nFROM Module", "SELECT 2"])
  }

  @Test func `the bundled views are the six COM-interface views`() {
    // The parse-and-register path a `CREATE VIEW` reuses; the six bundled
    // views register under their case-folded names.
    let views = Session.bundled()
    #expect(Set(views.keys)
            == ["interfaces", "methods", "params", "bases", "generics",
                "specs"])
  }

  @Test func `a streamed CREATE VIEW statement parses and registers a view`() throws {
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

  @Test func `a language spec parses its escape, void, root, keyword, and type keys`() {
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

  @Test func `the box renderer frames a header over a ruled multi-row grid`() {
    // The `.mode box` grid: a `┌─┬─┐` top, the header row, a `├─┼─┤` rule, one
    // line per row, and a `└─┴─┘` bottom, every cell padded one space each side.
    let table = Box.render(["Name", "Id"],
                           [[.text("IUnknown"), .integer(1)],
                            [.text("IInspectable"), .integer(2)]])
    #expect(table == """
      ┌──────────────┬────┐
      │ Name         │ Id │
      ├──────────────┼────┤
      │ IUnknown     │ 1  │
      │ IInspectable │ 2  │
      └──────────────┴────┘
      """)
  }

  @Test func `each column is sized to the widest of its header and its cells`() {
    // Column width is the max of the header and every cell's display width: the
    // first column is sized by its long cell (`elongated`), the second by its
    // header (`X`), which outsizes its one-character cells.
    let table = Box.render(["k", "X"],
                           [[.text("elongated"), .text("y")]])
    #expect(table == """
      ┌───────────┬───┐
      │ k         │ X │
      ├───────────┼───┤
      │ elongated │ y │
      └───────────┴───┘
      """)
  }

  @Test func `an empty result renders the header and frame alone`() {
    // With no rows the header row still prints between the top frame and the
    // header rule and bottom frame — sized to the header widths — so the column
    // names remain visible.
    #expect(Box.render(["Name", "Id"], []) == """
      ┌──────┬────┐
      │ Name │ Id │
      ├──────┼────┤
      └──────┴────┘
      """)
  }

  @Test func `a NULL or empty cell renders as blank padding`() {
    // A `.null` cell (and an empty `.text`) shows as the empty string — the way
    // the shell's list mode displays a NULL — padded to the column width. A row
    // shorter than the header pads its missing trailing cells empty too.
    let table = Box.render(["a", "b", "c"],
                           [[.null, .text(""), .text("v")],
                            [.text("x")]])
    #expect(table == """
      ┌───┬───┬───┐
      │ a │ b │ c │
      ├───┼───┼───┤
      │   │   │ v │
      │ x │   │   │
      └───┴───┴───┘
      """)
  }

  @Test func `a wide (double-width) cell is sized by its display columns`() {
    // A cell's width is measured in display columns, not bytes or scalars: a
    // fullwidth CJK character occupies two columns, so the column sizes to four
    // (two glyphs) rather than mis-sizing on its scalar count, keeping the frame
    // aligned.
    let table = Box.render(["h"], [[.text("中文")]])
    #expect(table == """
      ┌──────┐
      │ h    │
      ├──────┤
      │ 中文 │
      └──────┘
      """)
  }

  @Test func `the identity spec escapes nothing and applies no conventions`() {
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
