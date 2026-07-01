// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import Mustache
internal import SQL
internal import WinMD
internal import WinMDSynthesis

internal import class Foundation.Bundle
internal import class Foundation.FileManager
internal import struct Foundation.Data
internal import struct Foundation.URL

// MARK: - Metacommand

/// A `.`-meta-command — one of the shell's verbs that is not a SQL statement.
///
/// A statement whose leading token begins with `.` is a meta-command;
/// `Shell.execute` looks up the `Metacommand` type whose `spelling` matches that
/// token and runs it against the shell. Each command is one self-contained type:
/// the compiler enforces the `spelling`/`init`/`execute` trio, so adding a
/// command later is a new conformer plus one line in `Shell.commands`. Anything
/// that is not a `.`-statement is SQL.
internal protocol Metacommand {
  /// The leading token this command answers to, including the `.` — e.g.
  /// `".read"`.
  static var spelling: String { get }

  /// Builds the command from `arguments`, the rest of the statement after the
  /// spelling token.
  init(_ arguments: Substring)

  /// Runs the command against `shell`. A throw aborts the statement; `Quit`
  /// throws the loop's stop sentinel.
  func execute(against shell: inout Shell) throws
}

/// `.tables` — list the database's relations.
internal struct Tables: Metacommand {
  internal static let spelling = ".tables"

  internal init(_ arguments: Substring) {}

  internal func execute(against shell: inout Shell) throws {
    let relations = shell.session.storage.relations
    for index in 0 ..< relations.count { print("  \(relations[index])") }
  }
}

/// `.help` — print the command summary.
internal struct Help: Metacommand {
  internal static let spelling = ".help"

  internal init(_ arguments: Substring) {}

  internal func execute(against shell: inout Shell) throws {
    print(Shell.help)
  }
}

/// `.quit` — leave the shell. `execute` throws `Shell.Stop`, the sentinel the
/// loop catches to break.
internal struct Quit: Metacommand {
  internal static let spelling = ".quit"

  internal init(_ arguments: Substring) {}

  internal func execute(against shell: inout Shell) throws {
    throw Shell.Stop()
  }
}

/// `.read <path>` — run a file of `;`-separated SQL statements.
internal struct Read: Metacommand {
  internal static let spelling = ".read"

  /// The file path, the rest of the statement after `.read`.
  internal let path: String

  internal init(_ arguments: Substring) {
    path = arguments.trimmed
  }

  internal func execute(against shell: inout Shell) throws {
    guard !path.isEmpty else { throw Shell.MetaError.unknown(Read.spelling) }
    try shell.read(path)
  }
}

/// `.render <interface> <template>` — render a COM interface (or `*` for every
/// interface) through a bundled Mustache template.
internal struct Render: Metacommand {
  internal static let spelling = ".render"

  /// The interface to render, or `*` for every interface.
  internal let interface: String

  /// The template to render it through.
  internal let template: String

  internal init(_ arguments: Substring) {
    let fields = arguments.split(whereSeparator: \.isWhitespace)
    if fields.count == 2 {
      interface = String(fields[0])
      template = String(fields[1])
    } else {
      interface = ""
      template = ""
    }
  }

  internal func execute(against shell: inout Shell) throws {
    guard !interface.isEmpty, !template.isEmpty else {
      throw Shell.MetaError.unknown(Render.spelling)
    }
    print(try shell.render(interface, template: template))
  }
}

// MARK: - Shell

/// The interactive `query` shell — a `sqlite3`-style REPL — driving a `Session`.
///
/// `Shell` is a context-holding value, not a static namespace: it owns the
/// mutable `session` (the catalog state) and is the single place execution
/// lives. `execute(_:)` runs one yielded `Statements` element: a statement whose
/// first token begins with `.` is a `Metacommand` looked up in `commands` and
/// run; anything else is a SQL statement run through `Session.run` — a `CREATE
/// VIEW` registers, a `SELECT` returns rows — whose rows the shell prints,
/// without singling out `CREATE VIEW`. The streaming (`Statements`), the
/// per-statement execution (`execute(_:)`), and the driving (the `for`-in in
/// `Query.run` and `.read`) are three separate pieces — there is no loop
/// abstraction. It is `~Escapable` because the `Session` it holds borrows the
/// database's `Storage`.
internal struct Shell: ~Escapable {
  /// The shell's mutable catalog state.
  internal var session: Session

  /// Whether a statement fault ends the run (an explicit batch) or is reported
  /// to stderr and skipped (the interactive/redirected shell). `.read` inherits
  /// it through `attempt`, so an included script applies the same policy as its
  /// text fed on stdin.
  private let strict: Bool

  /// The `-I` override directories, tried before the package bundle when a
  /// query, view, or template resource is loaded — a later directory shadows an
  /// earlier one and the bundle (the last `-I` wins).
  private let search: Array<String>

  /// Opens a shell over `storage`, seeding the session's bundled views.
  /// `strict` defaults to the forgiving shell policy; an explicit batch passes
  /// `true`. `search` is the `-I` override directories, tried before the
  /// bundle.
  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage, strict: Bool = false,
                search: Array<String> = []) {
    session = Session(storage, search: search)
    self.strict = strict
    self.search = search
  }

  /// The registry of meta-commands — `execute(_:)` matches a leading `.`-token
  /// against each type's `spelling`. Adding a command is one line here. It is
  /// computed so the metatype array (not `Sendable`) is not a shared mutable
  /// global.
  private static var commands: Array<any Metacommand.Type> {
    [Tables.self, Help.self, Quit.self, Read.self, Render.self]
  }

  /// The command summary `.help` prints.
  internal static let help = """
    .tables                 list the database's tables
    .read <path>            run a file of `;`-separated SQL statements
    .render <iface> <tmpl>  render an interface (or `*`) through a template
    .help                   show this help
    .quit                   leave the shell
    <sql>                   run a SQL statement (trailing `;` optional)
    """

  /// The sentinel `Quit.execute` throws to stop the loop — caught by the
  /// driving `for`-in, never surfaced to the user.
  internal struct Stop: Error {}

  /// A fault a meta-command raises.
  internal enum MetaError: Error, Equatable {
    /// An unrecognised or malformed `.`-command (the offending token).
    case unknown(String)
  }

  /// A fault `.render` raises that is not already a `SQLError`.
  internal enum RenderError: Error, Equatable {
    /// No interface in the `interfaces` view bears the requested name.
    case interface(String)
    /// No template resource of the requested name resolved — neither a `-I`
    /// directory's `Templates/<name>.mustache` nor the bundled one.
    case template(String)
    /// No render-query resource of the requested name resolved — neither a `-I`
    /// directory's `Render/<name>.sql` nor the bundled one.
    case query(String)
  }

  // MARK: - Execute

  /// Runs one yielded `statement` against the session.
  ///
  /// A statement whose leading token begins with `.` is a meta-command: the
  /// matching `Metacommand` type is built from the rest of the statement and
  /// run; an unknown `.`-token is a `MetaError.unknown`. Anything else is a SQL
  /// statement, run through `Session.run` — a `CREATE VIEW` registers, a `SELECT`
  /// yields rows — and its rows print tab-separated. The shell does not single
  /// out `CREATE VIEW`: it just runs the statement and prints what comes back.
  internal mutating func execute(_ statement: String) throws {
    guard statement.first == "." else {
      for row in try session.run(statement.statement) {
        print(row.map(\.display).joined(separator: "\t"))
      }
      return
    }
    let spelling = statement.prefix { !$0.isWhitespace }
    let arguments = statement.dropFirst(spelling.count)
    guard let command =
        Shell.commands.first(where: { $0.spelling == spelling })
    else { throw MetaError.unknown(statement) }
    try command.init(arguments).execute(against: &self)
  }

  /// Runs one statement under the run's error policy — the single place that
  /// policy lives, so the top-level driver and `.read` cannot diverge. `.quit`'s
  /// `Stop` always propagates (ending the session); any other fault propagates
  /// when `strict` (an explicit batch aborts) and is otherwise reported to
  /// stderr and swallowed so the driver reads on.
  internal mutating func attempt(_ statement: String) throws {
    do {
      try execute(statement)
    } catch let error where !(error is Stop) {
      if strict { throw error }
      note("error: \(error)")
    }
  }

  /// Runs the `;`-separated SQL statements in the file at `path` — the `.read`
  /// meta-command (the `sqlite3` analogue).
  ///
  /// Each statement runs through `attempt`, so the included file applies the
  /// run's own policy: an explicit batch fails fast on the first fault, while
  /// the interactive/redirected shell reports it and reads on — an included
  /// script behaves exactly like its text fed on stdin. `.quit`'s `Stop`
  /// propagates in both, ending the session. A missing or unreadable file
  /// throws, which the caller's own `attempt` then treats the same way.
  internal mutating func read(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let text = String(decoding: data, as: UTF8.self)
    for statement in Statements(of: text) { try attempt(statement) }
  }

  // MARK: - Render

  /// Renders the interface named `interface`, or every interface for `*`,
  /// through the named Mustache template.
  ///
  /// The data tier is the session's bundled views, read through the
  /// bundled `Resources/Render/*.sql` queries (not Swift literals): the
  /// `interfaces` query selects the one named interface, or every
  /// interface for `*` (its `WHERE TypeName = :name OR '*' = :name`), then
  /// for each its `methods` bound by the interface's `rowid`, each
  /// method's `params` bound by the method's `rowid`, and its `bases`
  /// bound by the interface's `rowid`. The presentation tier is the named
  /// template loaded from `Resources/Templates`. A single interface that
  /// no view names raises `RenderError.interface`; a missing template
  /// resource raises `RenderError.template`.
  ///
  /// The base inheritance is derived through the `bases` view (the interface's
  /// `InterfaceImpl` rows navigated to their base type names); a rootless
  /// interface defaults to the spec's COM `root`, save the root interface
  /// itself, which inherits nothing. Identifier escaping and the no-value return
  /// come from the template's language spec (`ESCAPE`/`RETURNS`), not the binary.
  internal borrowing func render(_ interface: String,
                                 template: String) throws -> String {
    // The template names its own target language through a leading `{{! language:
    // <name> }}` directive; stripping it yields the body and loads the matching
    // spec, whose render UDFs (`ESCAPE`, `RETURNS`) make identifier escaping and
    // the no-value return the queries' concern, not the binary's.
    var body = try Shell.template(named: template, search: search)
    let language = Shell.language(declaredIn: &body, search: search)
    let routines = language.routines
    // The type spellings are decoded at render time from the spec's `Dialect`:
    // the adapter is language-neutral, so the render — not the binary's WinMD →
    // SQL layer — spells a return/parameter, navigating the signature with the
    // free `decodedReturn`/`decodedParameter` functions.
    let dialect = language.dialect
    // The rows to render come straight from the bundled selection query, bound
    // by `:name`: it returns the one named interface, or — for `*` — every one
    // (`WHERE TypeName = :name OR '*' = :name`). Choosing which rows to emit is
    // the query's job, so render just iterates whatever it returns.
    let selection =
        try Shell.select(Shell.query(named: "interfaces", search: search))
    let interfaces = try Engine.run(selection, session, routines,
                                    bindings: ["name": .text(interface)])
    guard interface == "*" || !interfaces.isEmpty else {
      throw RenderError.interface(interface)
    }

    let mustache = try MustacheTemplate(string: body)
    var sources = Array<String>()
    sources.reserveCapacity(interfaces.count)
    for found in interfaces {
      let rowid = found[0]
      // The interface's methods, bound by its rowid; each row is its `rowid`
      // then its escaped `Name`. The type spellings are no longer projected —
      // the render decodes them from the signature with the spec's `Dialect`.
      let plan = try Shell.select(Shell.query(named: "methods",
                                              search: search))
      let rows = try Engine.run(plan, session, routines,
                                bindings: ["parent": rowid])
      var methods = Array<Dictionary<String, Any>>()
      methods.reserveCapacity(rows.count)
      for method in rows {
        // Each method's parameters, bound by the method's rowid; each row is its
        // `rowid`, escaped `Name`, and `Sequence`. The return pseudo-parameter
        // (`Sequence == 0`) is dropped — only the real parameters spell the
        // requirement's arguments — and the rest decode their type at render
        // time from the parameter's own signature position.
        let selection = try Shell.select(Shell.query(named: "params",
                                                     search: search))
        let params = try Engine.run(selection, session, routines,
                                    bindings: ["parent": method[0]])
        var parameters = Array<Dictionary<String, Any>>()
        for parameter in params where parameter[2] != .integer(0) {
          let type = decodedParameter(of: parameter[0].integer,
                                      in: session.storage, dialect: dialect)
          parameters.append([
            "name": parameter[1].text,
            "type": type ?? "",
            "last": false,
          ])
        }
        // The trailing parameter's `last` flag drives the template's
        // `{{^last}}, {{/last}}` comma separation, omitting the final comma.
        if !parameters.isEmpty {
          parameters[parameters.count - 1]["last"] = true
        }
        var entry: Dictionary<String, Any> = [
          "name": method[1].text,
          "params": parameters,
        ]
        // The return, decoded at render time; a no-value return (the spec's
        // `void` spelling, or an undecodable return) leaves `returns` absent, so
        // the template's `{{#returns}}` clause renders nothing.
        let returned = decodedReturn(of: method[0].integer, in: session.storage,
                                     dialect: dialect)
        if let returned, let clause = language.returned(returned) {
          entry["returns"] = clause
        }
        methods.append(entry)
      }
      // The interface's base, via the `bases` view bound by its rowid. A
      // rootless interface defaults to the spec's COM root, except the root
      // interface itself — which inherits nothing, so it never becomes its own
      // base; an empty `root` applies no default.
      let lineage =
          try Shell.select(Shell.query(named: "bases", search: search))
      let bases = try Engine.run(lineage, session, routines,
                                 bindings: ["parent": rowid])
      let base: String? = if let inherited = bases.first {
        inherited[0].text
      } else if language.root.isEmpty || found[2].text == language.root {
        nil
      } else {
        language.root
      }
      var context: Dictionary<String, Any> = [
        "name": found[2].text,
        "iid": found[3].text,
        "namespace": found[1].text,
        "methods": methods,
      ]
      // An absent `base` skips the template's `{{#base}}` inheritance clause.
      if let base { context["base"] = base }
      sources.append(mustache.render(context))
    }
    return sources.joined(separator: "\n")
  }

  /// The text of the Mustache template named `name`, loaded through the search
  /// path (a `-I` directory's `Templates/<name>.mustache`) then the bundled
  /// `Resources/Templates/<name>.mustache`.
  ///
  /// The render's presentation tier is a named resource, not a literal: `com`
  /// is the one bundled template (the `@com` protocol shape), and adding a
  /// target later is dropping in another `.mustache` beside it — or shadowing
  /// one through a `-I` directory — no code change. A name no search directory
  /// and no bundle resolves raises `RenderError.template`.
  ///
  /// The `com` template emits the `@com` protocol style: a leading `{{! language:
  /// swift }}` directive naming its spec, the `@com(interface:)` attribute, `public
  /// protocol <name>` with an optional `: <base>` clause, and one
  /// four-space-indented `func` requirement per method — each parameter `_
  /// <name>: <type>`, comma-separated through the parameters' `last` flag, and an
  /// optional ` -> <returns>` clause. Each optional is driven off the value's
  /// presence (`{{#base}}`/`{{#returns}}`). Its interpolations are triple-mustache
  /// (`{{{…}}}`, raw) rather than double: the output is Swift source, not HTML, so
  /// the type spellings' angle brackets (`UnsafePointer<…>`) must not be escaped.
  private static func template(named name: String,
                               search: Array<String>) throws -> String {
    guard let url = resource(name, "mustache", kind: "Templates",
                             search: search)
    else { throw RenderError.template(name) }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
  }

  /// The text of the render query named `name`, loaded through the search path
  /// (a `-I` directory's `Render/<name>.sql`) then the bundled
  /// `Resources/Render/<name>.sql`.
  ///
  /// The render's data tier — the `SELECT`s that read the bundled views — is
  /// resource data, not Swift literals: each is a `Render/<name>.sql` loaded by
  /// name (a `-I` directory's copy shadowing the bundle's), the same way the
  /// template is. A name no search directory and no bundle resolves is a
  /// packaging error, raised as `RenderError.query`.
  private static func query(named name: String,
                            search: Array<String>) throws -> String {
    guard let url = resource(name, "sql", kind: "Render", search: search)
    else { throw RenderError.query(name) }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
  }

  /// Parses `text` as a `SELECT`, returning its `SQL.Query`.
  ///
  /// The render's queries are static, well-formed `SELECT`s, so a parse failure
  /// or a non-`SELECT` is a programming error; it surfaces as the thrown error.
  /// The return type is spelled `SQL.Query` — the module's own `Query` is the
  /// `ParsableCommand` subcommand, not the SQL AST.
  private static func select(_ text: String) throws -> SQL.Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      throw SQLError.incomplete(expected: "a SELECT")
    }
    return query
  }

  /// The target-language spec a template body declares, consuming its leading
  /// `{{! language: <name> }}` directive.
  ///
  /// A template is written for a target language, and it names that language in a
  /// leading Mustache-comment directive so the association is the template
  /// author's, in data — not a mapping compiled into the binary. This strips the
  /// directive line from `body` (leaving a clean template) and loads
  /// `<name>.lang`; a body with no directive keeps its text and gets the identity
  /// `Language` (no escaping, no conventions).
  private static func language(declaredIn body: inout String,
                               search: Array<String>) -> Language {
    guard let newline = body.firstIndex(where: \.isNewline) else {
      return Language()
    }
    let directive = body[..<newline].trimmed
    let opening = "{{! language:", closing = "}}"
    guard directive.hasPrefix(opening), directive.hasSuffix(closing) else {
      return Language()
    }
    let name =
        directive.dropFirst(opening.count).dropLast(closing.count).trimmed
    body = String(body[body.index(after: newline)...])
    return Shell.language(named: name, search: search)
  }

  /// The target-language spec named `name`, loaded through the search path (a
  /// `-I` directory's `Languages/<name>.lang`) then the bundled
  /// `Resources/Languages/<name>.lang`. A name no search directory and no bundle
  /// resolves gives the identity `Language`, so a template may declare a language
  /// with no spec (or none at all) and still render — verbatim.
  private static func language(named name: String,
                              search: Array<String>) -> Language {
    guard let url = resource(name, "lang", kind: "Languages", search: search),
        let data = try? Data(contentsOf: url) else {
      return Language()
    }
    return Language(parsing: String(decoding: data, as: UTF8.self))
  }
}

/// Locates resource `<name>.<ext>` of the given `kind` (`Render`, `Queries`,
/// or `Templates`), preferring a user override: the search directories are
/// tried last-first as `<dir>/<kind>/<name>.<ext>` (so a later `-I` wins over
/// an earlier one), then the package bundle's `Resources/<kind>/<name>.<ext>`.
/// `nil` when none has it.
private func resource(_ name: String, _ ext: String, kind: String,
                      search: Array<String>) -> URL? {
  for directory in search.reversed() {
    let path = "\(directory)/\(kind)/\(name).\(ext)"
    if FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
  }
  return Bundle.module.url(forResource: name, withExtension: ext,
                           subdirectory: "Resources/\(kind)")
}

// MARK: - Statements

/// The statement stream a `for`-in drives — the input's statements yielded one
/// at a time from a line source.
///
/// `Statements` is a `Sequence` over a *line source* (a `() -> String?` — either
/// `readLine` for stdin, or the lines of a `String` for the argument and
/// `.read`). Its iterator reads lines and yields either a whole `.`-prefixed
/// meta statement, or a SQL statement accumulated across lines until a
/// terminating `;`. This is the `;`-accumulation the old loop did, lifted into
/// an ordinary iterator so the driving is a literal `for`-in.
internal struct Statements: Sequence {
  /// The line source — `readLine` for stdin, or a closure over a string's
  /// lines for the argument and `.read`.
  private let lines: () -> String?

  /// A hook called before each line is read, told whether a statement is
  /// pending (a mid-accumulation, unterminated statement). The interactive
  /// shell passes one to emit its primary/continuation prompt; the argument and
  /// `.read` paths leave it `nil` so a batch never prompts.
  private let prompt: ((Bool) -> Void)?

  /// Streams statements read line-by-line from `lines`, optionally calling
  /// `prompt` before each read with whether a statement is pending — the
  /// interactive shell's prompt hook.
  internal init(reading lines: @escaping () -> String?,
                prompt: ((Bool) -> Void)? = nil) {
    self.lines = lines
    self.prompt = prompt
  }

  /// Streams the statements of `text`, reading its lines. A batch never
  /// prompts, so it has no prompt hook.
  internal init(of text: String) {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .makeIterator()
    self.lines = { lines.next() }
    prompt = nil
  }

  internal func makeIterator() -> Iterator {
    Iterator(lines, prompt)
  }

  /// The statement iterator — the `;`-accumulator over the line source.
  internal struct Iterator: IteratorProtocol {
    /// The line source the iterator pulls from.
    private let lines: () -> String?

    /// The prompt hook, called before each read with whether a statement is
    /// pending; `nil` for a batch, which never prompts.
    private let prompt: ((Bool) -> Void)?

    /// The SQL accumulated across lines, not yet closed by a `;`.
    private var pending: String

    internal init(_ lines: @escaping () -> String?,
                  _ prompt: ((Bool) -> Void)?) {
      self.lines = lines
      self.prompt = prompt
      pending = ""
    }

    /// The next statement, or `nil` at end of input.
    ///
    /// A `.`-meta line (when no statement is pending) yields whole. Otherwise
    /// lines accumulate until a `;` closes a statement, which yields; a trailing
    /// unterminated statement yields at end of input — the closing `;` is
    /// optional, so a one-shot query or a file without a final terminator runs
    /// its last statement.
    internal mutating func next() -> String? {
      while true {
        // Drain any completed statement already accumulated.
        if let semicolon = Iterator.terminator(in: pending) {
          let statement = String(pending[..<semicolon]).trimmed
          pending = String(pending[pending.index(after: semicolon)...])
          guard statement.isEmpty else { return statement }
          continue
        }
        // Prompt before the read (the interactive shell only): a pending,
        // unterminated statement asks for its continuation; an empty one asks
        // for a fresh statement. A batch's hook is `nil`, so it never prompts.
        prompt?(!pending.trimmed.isEmpty)
        guard let line = lines() else {
          // End of input: flush a final unterminated statement (the closing
          // `;` is optional), then clear `pending` so the next call stops.
          let statement = pending.trimmed
          pending = ""
          return statement.isEmpty ? nil : statement
        }
        // A `.`-meta line yields whole when no statement is pending — a
        // whitespace-only spacer line before it is nothing, so drop it rather
        // than gluing the meta line onto it.
        if pending.trimmed.isEmpty, line.trimmed.first == "." {
          pending = ""
          return line.trimmed
        }
        pending += pending.isEmpty ? line : "\n" + line
      }
    }

    /// The index in `text` of the first `;` that terminates a statement — one
    /// outside a single-quoted string literal — or `nil` when there is none
    /// (including when `text` trails off inside a literal whose closing quote
    /// has not arrived yet). A `;` inside `'…'` is data, not a terminator, so
    /// the split matches what the SQL lexer scans (`''` is an escaped quote).
    private static func terminator(in text: String) -> String.Index? {
      var index = text.startIndex
      var quoted = false
      while index < text.endIndex {
        let character = text[index]
        if quoted {
          // A doubled `''` is an escaped quote: consume it and stay inside the
          // literal. A lone `'` closes the literal.
          if character == "'" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "'" {
              index = next
            } else {
              quoted = false
            }
          }
        } else if character == "'" {
          quoted = true
        } else if character == ";" {
          return index
        }
        index = text.index(after: index)
      }
      return nil
    }
  }
}

// MARK: - Session

extension Session {
  /// Runs one SQL `statement` against the session, returning the rows a
  /// `SELECT` yields — or none for a `CREATE VIEW`, which registers its `View`
  /// (the key case-folded, the way the catalog resolves it) instead. `CREATE
  /// VIEW` is an ordinary statement here, not a special case; the shell prints
  /// whatever rows come back.
  internal mutating func run(_ statement: String)
      throws -> Array<Array<Value>> {
    switch try Statement(parsing: statement) {
    case let .create(name, view):
      register(name, view)
      return []
    case let .select(query):
      return try Engine.run(query, self)
    }
  }
}

// MARK: - Bundled views

extension Session {
  /// The session's built-in views, keyed case-folded — the union of the bundled
  /// query resources and any a `-I` search directory adds, each parsed the way
  /// a `CREATE VIEW` line registers, so a test (or the session's seed) can
  /// build the dictionary without driving the shell.
  ///
  /// This is the general seed operation: gather the view names from the bundled
  /// query set (`Resources/Queries/*.sql`) and every search directory's
  /// `Queries/*.sql`, then for each name load the first search directory that
  /// has it (else the bundle), parse it as a `CREATE VIEW`, and register it —
  /// so a `-I` directory both shadows an existing view and adds a new one. The
  /// four COM-interface views are the one bundled set, so adding a query later
  /// is dropping in another `.sql` beside them (or under a `-I` directory) — no
  /// code change. The views are order-independent (none references another), so
  /// the enumeration order does not matter.
  ///
  /// These views denormalise a COM interface for rendering: an `interfaces`
  /// view that navigates each `TypeDef` to its `GuidAttribute` IID across the
  /// coded-index join keys — `TypeDef` ← `CustomAttribute.Parent_TypeDef`,
  /// then `CustomAttribute.Type_MemberRef` → `MemberRef`, then
  /// `MemberRef.Class_TypeRef` → `TypeRef`, filtered to the `GuidAttribute`
  /// declaring type, projecting `CustomAttribute.guid` as the `iid` — a
  /// `methods` view of one interface's methods, a `params` view of one
  /// method's parameters, and a `bases` view of one interface's base type. The
  /// latter three carry a uniform `:parent` param — the owning row's `rowid` —
  /// so a render can walk interface → methods → params, binding each level's
  /// `rowid` to the next's `:parent`, and look up the interface's base by its
  /// `rowid`.
  ///
  /// The `bases` view navigates the interface's single `InterfaceImpl` row
  /// (whose simple `Class` index is the interface's 1-based `rowid`) to its
  /// base type's simple name, projecting `TypeRef.TypeName` as `base`. The
  /// `Class` column is a *simple* `TypeDef` index — it stores the `rowid`
  /// directly, so the predicate is `i.Class = :parent` (there is no decoded
  /// `Class_TypeDef` join key — `WinMDRelation.keys` derives keys only for
  /// *coded* indices). `Interface` is the coded `TypeDefOrRef`, so its decoded
  /// `Interface_TypeRef` key equi-joins the base `TypeRef`. Both arms of the
  /// coded index resolve, `UNION`ed: a cross-file base through
  /// `Interface_TypeRef` (a `TypeRef`) and a same-file base through
  /// `Interface_TypeDef` (a `TypeDef` in this module).
  ///
  /// A query resource is static, well-formed SQL, so a parse failure is a
  /// programming error rather than user input; it is silently skipped here (the
  /// view simply does not register).
  internal static func bundled(search: Array<String> = [])
      -> Dictionary<String, View> {
    // The view names to seed: those bundled, plus any a search directory adds.
    var names = Set<String>()
    for url in Bundle.module.urls(forResourcesWithExtension: "sql",
                                  subdirectory: "Resources/Queries") ?? [] {
      // `urls(forResourcesWithExtension:)` vends `NSURL` on non-Darwin
      // Foundation, whose path API differs; bridge it to `URL`.
      names.insert((url as URL).deletingPathExtension().lastPathComponent)
    }
    for directory in search {
      let path = "\(directory)/Queries"
      let files =
          (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
      for file in files where file.hasSuffix(".sql") {
        names.insert(String(file.dropLast(4)))
      }
    }
    // Each name loads from the first search dir that has it, else the bundle.
    var views = Dictionary<String, View>()
    for name in names {
      guard let url = resource(name, "sql", kind: "Queries", search: search),
            let data = try? Data(contentsOf: url) else { continue }
      let text = String(decoding: data, as: UTF8.self).trimmed.statement
      if case let .create(view, definition)? = try? Statement(parsing: text) {
        views[view.lowercased()] = definition
      }
    }
    return views
  }
}

// MARK: - Helpers

extension StringProtocol {
  /// This text with leading and trailing whitespace removed — a stdlib-only
  /// trim (no Foundation `CharacterSet`).
  internal var trimmed: String {
    String(drop { $0.isWhitespace }.reversed()
               .drop { $0.isWhitespace }.reversed())
  }

  /// This statement with a single trailing `;` removed — the trailing `;` a
  /// query statement may carry is optional.
  internal var statement: String {
    hasSuffix(";") ? String(dropLast()) : String(self)
  }
}

extension Value {
  /// This typed cell's display string — a `NULL` as the empty string, the way
  /// `sqlite3`'s list mode shows it.
  internal var display: String {
    switch self {
    case .null:                 ""
    case let .integer(integer): "\(integer)"
    case let .text(text):       text
    }
  }

  /// This cell's `text`, the empty string for any non-text cell — the render
  /// only ever reads `.text` columns (names, types, the IID), so a non-text
  /// cell is a NULL the caller has already filtered.
  internal var text: String {
    if case let .text(text) = self { text } else { "" }
  }

  /// This cell's `integer`, zero for any non-integer cell — the render reads a
  /// `rowid`/`Sequence` `.integer` column to navigate a signature, so a
  /// non-integer cell is a NULL the query guarantees never appears there.
  internal var integer: Int {
    if case let .integer(integer) = self { integer } else { 0 }
  }
}
