// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import Mustache
internal import SQLEngine
internal import SQLEngineWinMD
internal import SQLShell
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

/// `.schema <query>` — print a query's result columns (name and type) WITHOUT
/// running it.
///
/// A query's result has a name and a type per column, which
/// `Catalog.columns(of:validate:)` derives by RESOLVING the query the way a run
/// would — but never opening a cursor, so the shape is inspectable over an
/// empty or costly source without paying for it. `arguments` is the query text
/// (a trailing `;` optional); it may be a `SELECT` (or a `UNION`) or a `WITH`,
/// the runnable shapes `columns(of:)` types — the SAME statements the shell
/// runs, so a CTE query describes as it executes. A `CREATE VIEW` names no
/// result columns and faults. `execute` prints one tab-separated
/// `<name>\t<type>` line per column, the type the ISO `data_type` spelling
/// `information_schema.columns` reports — a query that does not resolve (an
/// unknown relation, an unresolved column, a `WITH` whose body arity
/// contradicts its declared list) faults exactly as a run would, so `.schema`
/// doubles as a dry-run check.
internal struct Schema: Metacommand {
  internal static let spelling = ".schema"

  /// The query text whose result columns to describe — the rest of the
  /// statement after `.schema`, a trailing `;` optional.
  internal let query: String

  internal init(_ arguments: Substring) {
    query = arguments.trimmed.statement.trimmed
  }

  internal func execute(against shell: inout Shell) throws {
    if query.isEmpty { throw Shell.MetaError.unknown(Schema.spelling) }
    // Route through the statement-level, CTE-aware derive with `validate:
    // true`: it types a `SELECT`/`UNION` AND a `WITH` (the CTE scope kept in
    // place) and faults a `CREATE VIEW`, so `.schema` describes every runnable
    // statement the shell runs — the dry run validating the whole statement.
    let parsed = try Statement(parsing: query)
    let columns =
        try shell.session.columns(of: parsed, routines: shell.session.functions,
                                  validate: true)
    for column in columns {
      print("\(column.name)\t\(column.type.domain)")
    }
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
    if path.isEmpty { throw Shell.MetaError.unknown(Read.spelling) }
    try shell.read(path)
  }
}

/// `.bind <name> <value>` — bind (or clear) a `:name` parameter the shell
/// threads into every SQL statement it runs.
///
/// A parameterized query typed at the prompt (`WHERE col = :name`) needs its
/// `:name` bound, which the shell has no other way to supply; `.bind` fills that
/// gap. `arguments` is `<name> <value>`: the name is the first
/// whitespace-delimited token, the value the trimmed remainder, typed as an
/// `.integer` when it parses as an `Int`, else `.text` (a surrounding pair of
/// single quotes stripped and a doubled `''` unescaped to one `'`, so
/// `.bind s 'O''Hare'` binds the text `O'Hare`). A `.bind` with a name and no
/// value removes that binding.
internal struct Bind: Metacommand {
  internal static let spelling = ".bind"

  /// The parameter name — the first whitespace-delimited token of `arguments`.
  internal let name: String

  /// The value to bind, typed from the trimmed remainder — an `.integer` when it
  /// parses as an `Int`, else `.text` (a surrounding single-quote pair stripped
  /// and `''` unescaped to one `'`). `nil` when no value follows the name, which
  /// clears the binding.
  internal let value: Value?

  internal init(_ arguments: Substring) {
    let text = arguments.trimmed
    let split = text.firstIndex(where: \.isWhitespace)
    name = String(split.map { text[..<$0] } ?? text[...])
    let remainder = split.map { text[$0...].trimmed } ?? ""
    value = if remainder.isEmpty {
      nil
    } else if let integer = Int(remainder) {
      .integer(integer)
    } else if remainder.first == "'" {
      .text(unquote(remainder))
    } else {
      .text(remainder)
    }
  }

  internal func execute(against shell: inout Shell) throws {
    if name.isEmpty { throw Shell.MetaError.unknown(Bind.spelling) }
    if let value {
      shell.bindings[name] = value
      note("bound :\(name) = \(value.display)")
    } else {
      shell.bindings[name] = nil
      note("cleared :\(name)")
    }
  }
}

/// `.render <interface> <template> [--closure]` — render a COM interface (or
/// `*` for every interface) through a bundled Mustache template.
///
/// Without `--closure` the render is the interface's own surface, exactly as
/// before. With `--closure` and a concrete interface, the render is that
/// interface plus the transitive closure of its plain (`spec IS NULL`) base and
/// required interfaces (the E1 edges). `*` keeps meaning the flat enumeration of
/// every interface, so `--closure` with `*` is the same flat enumeration.
internal struct Render: Metacommand {
  internal static let spelling = ".render"

  /// The interface to render, or `*` for every interface.
  internal let interface: String

  /// The template to render it through.
  internal let template: String

  /// Whether to render the interface's transitive base/required-interface
  /// closure (the `--closure` flag) rather than the interface alone. Ignored for
  /// `*`, which stays the flat enumeration of every interface.
  internal let closure: Bool

  internal init(_ arguments: Substring) {
    let fields = arguments.split(whereSeparator: \.isWhitespace)
    // The `--closure` flag may appear in any position; the two remaining
    // whitespace fields are still the interface and template, so a missing
    // operand leaves them empty and `execute` rejects the command.
    let operands = fields.filter { $0 != "--closure" }
    if operands.count == 2 {
      interface = String(operands[0])
      template = String(operands[1])
    } else {
      interface = ""
      template = ""
    }
    closure = fields.contains { $0 == "--closure" }
  }

  internal func execute(against shell: inout Shell) throws {
    if interface.isEmpty || template.isEmpty {
      throw Shell.MetaError.unknown(Render.spelling)
    }
    // A concrete interface under `--closure` renders its base closure; `*`
    // stays the flat enumeration even when the flag is present.
    if closure && interface != "*" {
      print(try shell.render(closure: interface, template: template))
    } else {
      print(try shell.render(interface, template: template))
    }
  }
}

/// `.template <name> '<body>'` — define a Mustache template inline as a single-
/// quoted (possibly multiline) string literal, then render through it.
///
/// A template is usually a file; this lets one be written at the prompt with no
/// file and no magic terminator. `arguments` is `<name> '<body>'`: the name is
/// the first whitespace-delimited token, the body the single-quoted literal that
/// follows — from the first `'` to its matching close, with `''` unescaped to a
/// literal `'`. Because the body is quote-delimited DATA, `.end`, `;`, `{{…}}`,
/// and `"` all appear verbatim; only a literal `'` needs doubling. The stream's
/// open-quote accumulation (`Statements`) hands the whole multiline block here as
/// one statement. `execute` stores the body in the shell's `templates`, so a
/// later `.render <iface> <name>` renders through it (shadowing a file); the body
/// still declares its language with a leading `{{! language: … }}` directive, the
/// same as a file template.
internal struct Template: Metacommand {
  internal static let spelling = ".template"

  /// The template name — the first whitespace-delimited token of `arguments`.
  internal let name: String

  /// The template body — the single-quoted literal after the name, `''`
  /// unescaped to a literal `'`. Empty when no quoted literal follows the name.
  internal let body: String

  internal init(_ arguments: Substring) {
    let text = arguments.trimmed
    let split = text.firstIndex(where: \.isWhitespace)
    name = String(split.map { text[..<$0] } ?? text[...])
    let rest = split.map { text[$0...].trimmed } ?? ""
    body = unquote(rest)
  }

  internal func execute(against shell: inout Shell) throws {
    if name.isEmpty { throw Shell.MetaError.unknown(Template.spelling) }
    shell.templates[name] = body
    note("defined template \(name)")
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
/// without singling out `CREATE VIEW`. The shell threads its `bindings` (set by
/// `.bind`) into every SQL statement, so a parameterized query typed at the
/// prompt (`WHERE col = :name`) resolves its `:name` from them. The streaming
/// (`Statements`), the
/// per-statement execution (`execute(_:)`), and the driving (the `for`-in in
/// `Query.run` and `.read`) are three separate pieces — there is no loop
/// abstraction. It is `~Escapable` because the `Session` it holds borrows the
/// database's `Storage`.
internal struct Shell: ~Escapable {
  /// The shell's mutable catalog state.
  internal var session: Session

  /// The `:name` parameters `.bind` has set, threaded into every SQL statement
  /// the shell runs so a parameterized query typed at the prompt (`WHERE col =
  /// :name`) resolves. Empty initially; a `CREATE VIEW` ignores them, binding
  /// only when a later `SELECT` reads the view.
  internal var bindings: Bindings = [:]

  /// The inline templates `.template` has defined, keyed by name. Empty
  /// initially; `template(named:)` returns one when present, so an inline
  /// template shadows a `-I` directory's file and the bundle for the session.
  internal var templates: Dictionary<String, String> = [:]

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
    [Schema.self, Help.self, Quit.self, Read.self, Render.self,
     Bind.self, Template.self]
  }

  /// The command summary `.help` prints.
  internal static let help = """
    .schema <query>         print a query's result columns without running it
    .read <path>            run a file of `;`-separated SQL statements
    .render <iface> <tmpl>  render an interface (or `*`) through a template
    .render … --closure     also render the interface's base-interface closure
    .bind <name> <value>    bind a `:name` parameter (no value clears it)
    .template <name> '…'    define an inline Mustache template (multiline
                            single-quoted; `''` for a literal quote; declare
                            the language with a leading `{{! language: … }}`)
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
  /// statement, run through `Session.run` with the shell's `bindings` — a `CREATE
  /// VIEW` registers, a `SELECT` yields rows resolving any `:name` from the
  /// bindings — and its rows print as a `sqlite3`-style `.mode box` table
  /// (`Box.render`), the column headers derived from the statement's result
  /// schema. The shell does not single out `CREATE VIEW`: it just runs the
  /// statement and prints what comes back — a `CREATE VIEW` yields no rows, so
  /// nothing prints.
  internal mutating func execute(_ statement: String) throws {
    guard statement.first == "." else {
      let text = statement.statement
      let rows = try session.run(text, bindings: bindings)
      // A row-producing statement (`SELECT`/`WITH`) prints its box even when the
      // result is empty — the header frame still conveys the zero-row result — so
      // an empty result is NOT treated as no output. A `CREATE VIEW` genuinely
      // produces nothing; `headers` returns nil for it and it is skipped.
      guard let names = headers(of: text, rows) else { return }
      print(Box.render(names, rows))
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
    for statement in Statements(of: text, multiline: [Template.spelling]) {
      try attempt(statement)
    }
  }

  // MARK: - Render

  /// Renders the interface named `interface`, or every interface for `*`,
  /// through the named Mustache template.
  ///
  /// The data tier is the session's bundled views, read through the
  /// bundled `Resources/Render/*.sql` queries (not Swift literals): the
  /// `interfaces` query selects the one named interface, or every
  /// interface for `*` (its `WHERE TypeName = :name OR '*' = :name`), then
  /// for each its `methods` bound by the interface's `Id`, each
  /// method's `params` bound by the method's `Id`, and its `bases`
  /// bound by the interface's `Id`. The presentation tier is the named
  /// template loaded from `Resources/Templates`. A single interface that
  /// no view names raises `RenderError.interface`; a missing template
  /// resource raises `RenderError.template`.
  ///
  /// The base inheritance is derived through the `bases` view (the interface's
  /// `InterfaceImpl` rows navigated to their base type names); a rootless
  /// interface defaults to the spec's COM `root`, save the root interface
  /// itself, which inherits nothing. Identifier escaping comes from the
  /// template's language spec (the `SANITIZE` UDF), and the no-value return is
  /// decided in Swift (`returned(_:)`) — neither is baked into the binary.
  internal borrowing func render(_ interface: String,
                                 template: String) throws -> String {
    // The template names its own target language through a leading `{{! language:
    // <name> }}` directive; stripping it yields the body and loads the matching
    // spec, whose render UDF (`SANITIZE`) makes identifier escaping the
    // queries' concern, not the binary's — while the no-value return is decided
    // in Swift.
    // `self.` disambiguates the `template(named:)` accessor from the `template`
    // parameter that names the one to load.
    var body = try self.template(named: template, search: search)
    let language = Shell.language(declaredIn: &body, search: search)
    // The queries resolve against both the target-language spec's UDFs
    // (`SANITIZE`) and the session's routines (`session.functions`) — the
    // WinMD-domain UDFs (`GUID`, which the `interfaces` view spells its `iid`
    // through) and the standard prelude it is seeded with, PLUS every scalar
    // function a session `CREATE FUNCTION` has defined. Merging the session's
    // routines (not the static `Session.routines` prelude) gives the render the
    // same routine set a `SELECT`/`.schema` resolves through, so a session
    // helper is visible to the render SQL and to the session views it reads;
    // later-wins lets such a helper overlay a language spec's UDF.
    let routines = language.routines.merging(session.functions)
    // The type spellings are decoded at render time from the spec's `Dialect`:
    // the adapter is language-neutral, so the render — not the binary's WinMD →
    // SQL layer — spells a return/parameter, navigating the signature with the
    // storage's `decode(return:in:)`/`decode(parameter:for:)` methods.
    let dialect = language.dialect
    // The rows to render come straight from the bundled selection query, bound
    // by `:name`: it returns the one named interface, or — for `*` — every one
    // (`WHERE TypeName = :name OR '*' = :name`). Choosing which rows to emit is
    // the query's job, so render just iterates whatever it returns.
    let selection =
        try Shell.statement(Shell.query(named: "interfaces", search: search))
    let interfaces = try session.run(selection, routines,
                                     bindings: ["name": .text(interface)])
    guard interface == "*" || !interfaces.isEmpty else {
      throw RenderError.interface(interface)
    }

    let mustache = try MustacheTemplate(string: body)
    var sources = Array<String>()
    sources.reserveCapacity(interfaces.count)
    for found in interfaces {
      sources.append(try emit(found, through: mustache, routines: routines,
                              in: dialect, language: language, search: search))
    }
    return sources.joined(separator: "\n")
  }

  /// Renders the transitive closure of the interface named `root` and its plain
  /// (`spec IS NULL`) base and required interfaces — the E1 edges — through the
  /// named Mustache template.
  ///
  /// The setup is the flat render's: the template names its target language, and
  /// the render resolves against the language spec's UDFs merged with the
  /// session's routines. The root selection is the same `interfaces` query, so a
  /// name no interface bears raises `RenderError.interface`; a simple name borne
  /// by more than one namespace seeds each match. From each seed the walk visits
  /// the base and required interfaces depth-first, emitting a base before the
  /// interface that refines it, rendering each interface once (dedup by its local
  /// `TypeDef` Id). The per-interface body is the one `emit` the flat render
  /// runs, so the closure reuses the decode and emit rather than duplicating it.
  internal borrowing func render(closure root: String,
                                 template: String) throws -> String {
    var body = try self.template(named: template, search: search)
    let language = Shell.language(declaredIn: &body, search: search)
    let routines = language.routines.merging(session.functions)
    let dialect = language.dialect
    let selection =
        try Shell.statement(Shell.query(named: "interfaces", search: search))
    let roots = try session.run(selection, routines,
                                bindings: ["name": .text(root)])
    guard !roots.isEmpty else { throw RenderError.interface(root) }

    let mustache = try MustacheTemplate(string: body)
    // The interfaces already emitted, keyed on their local `TypeDef` Id, so the
    // mutually referential interface graph terminates and each renders once.
    var visited = Set<Int>()
    var sources = Array<String>()
    for seed in roots {
      try walk(seed, visited: &visited, into: &sources, through: mustache,
               routines: routines, in: dialect, language: language,
               search: search)
    }
    return sources.joined(separator: "\n")
  }

  /// Emits the interface `found` and, first, the transitive closure of its plain
  /// (`spec IS NULL`) base and required interfaces — a depth-first post-order
  /// over the E1 edges, so a base precedes the interface refining it.
  ///
  /// The `requires` query resolves each base and required interface to its local
  /// interface `TypeDef` row keyed on namespace and name, so a base that resolves
  /// to no local interface `TypeDef` — an external `TypeRef`-only frontier, or a
  /// local type that is no interface — is not returned and the walk simply stops
  /// there. The visited set (the local `TypeDef` Id) renders each interface once
  /// and terminates a cycle; the bases are walked in a stable namespace-then-name
  /// order so the emission is deterministic.
  private borrowing func walk(_ found: Array<Value>, visited: inout Set<Int>,
                              into sources: inout Array<String>,
                              through mustache: MustacheTemplate,
                              routines: Routines, in dialect: Dialect,
                              language: Language,
                              search: Array<String>) throws {
    guard visited.insert(found[0].integer).inserted else { return }
    let query =
        try Shell.statement(Shell.query(named: "requires", search: search))
    let bases = try session.run(query, routines,
                                bindings: ["parent": found[0]])
    let ordered = bases.sorted {
      ($0[1].text, $0[2].text) < ($1[1].text, $1[2].text)
    }
    for base in ordered {
      try walk(base, visited: &visited, into: &sources, through: mustache,
               routines: routines, in: dialect, language: language,
               search: search)
    }
    sources.append(try emit(found, through: mustache, routines: routines,
                            in: dialect, language: language, search: search))
  }

  /// Renders the single interface `found` — its `Id`, namespace, name, and
  /// `iid`, the row shape the `interfaces` and `requires` queries share —
  /// through `mustache`, the per-interface body the flat render and the
  /// `--closure` walk both run.
  ///
  /// Decoding the interface's declared generics, methods, and base is the same
  /// work either path needs; wrapping it here is what lets the closure worklist
  /// reuse the decode and emit rather than duplicate them.
  private borrowing func emit(_ found: Array<Value>,
                              through mustache: MustacheTemplate,
                              routines: Routines, in dialect: Dialect,
                              language: Language,
                              search: Array<String>) throws -> String {
    let id = found[0]
    // The interface's ordered declared generic-parameter names, through the
    // `generics` view bound by its `Id` — empty for a non-generic interface.
    // A generic interface declares at least one; its own name then carries a
    // CLR arity suffix, stripped below. The names thread into the
    // method/parameter/return decode so a `VAR` spells its declared name
    // (`Element`) rather than a positional placeholder (`T0`).
    let names = try declarations(of: id, routines, search: search)
    // The names supplied to decode when the interface is generic; `nil`
    // otherwise, so a non-generic interface decodes exactly as before.
    let generics: Array<String>? = names.isEmpty ? nil : names
    // The interface's own methods, decoded with its generic names so a `VAR`
    // spells its declared name. A generic interface that has a base renders
    // only its own surface here; forwarding a base's inherited methods onto
    // the wrapper is a follow-up.
    let methods = try self.methods(of: id, routines, search: search,
                                   generics: generics, in: dialect,
                                   language: language)
    // The interface's named base, via the `bases` view bound by its `Id`. The
    // render query projects only the plain (`TypeRef`/`TypeDef`) bases, whose
    // simple `TypeName` is keyword-escaped here the way the interface's own
    // name is; a generic (`TypeSpec`) base is resolved by the `bases` view
    // but omitted from the render, pending the WinRT generic-inheritance
    // projection redesign. A rootless interface defaults to the spec's COM
    // root, except the root interface itself — which inherits nothing, so it
    // never becomes its own base; an empty `root` applies no default.
    let lineage =
        try Shell.statement(Shell.query(named: "bases", search: search))
    let bases = try session.run(lineage, routines, bindings: ["parent": id])
    let base: String? = if let inherited = bases.first {
      language.escape(inherited[0].text)
    } else if language.root.isEmpty || found[2].text == language.root {
      nil
    } else {
      language.root
    }
    // A generic interface's own `TypeName` carries the CLR arity suffix
    // (`IVector``1`); strip it — the decode tier strips it only for a
    // `GENERICINST` use, so the declaration name must be stripped here — so
    // the emitted name is `IVector`, its `<T>` clause supplied separately.
    // The keyword escape (`SANITIZE`) is applied here, on the stripped name,
    // not in the `interfaces` query: escaping the suffixed name would spare a
    // generic whose stripped name is a keyword (`protocol``1` is not the
    // reserved word `protocol`), leaving `public struct protocol` to be
    // emitted. Escaping after the strip is why the query projects the raw
    // `TypeName` — the interface's own name is the one identifier the strip
    // must precede the escape for, so its escape lives in Swift, not the SQL.
    let stripped = String(found[2].text.prefix { $0 != "`" })
    let name = language.escape(stripped)
    // The ABI-protocol name is the wrapper's own name suffixed with `ABI`,
    // used for both the ABI protocol's declaration and the wrapper's `base:
    // any …ABI<…>` existential. The `ABI` suffix must precede the escape (the
    // same order the base-name spelling uses): a keyword name's `<name>ABI`
    // is never itself a keyword (no Swift keyword ends in `ABI`), so escaping
    // the suffixed name is a no-op yielding a plain `protocolABI` — whereas
    // escaping first then appending `ABI` would splice a backtick pair into
    // the middle (`` `protocol`ABI ``), which Swift cannot parse.
    let abi = language.escape(stripped + "ABI")
    var context: Dictionary<String, Any> = [
      "name": name,
      "abi": abi,
      "iid": found[3].text,
      "namespace": found[1].text,
      "methods": methods,
    ]
    // An absent `base` skips the template's `{{#base}}` inheritance clause.
    if let base { context["base"] = base }
    // A generic interface carries its `generic` flag and its ordered clause
    // `generics` (each with a `last` flag for comma separation); a
    // non-generic one carries neither, so the template's `{{#generic}}` guard
    // leaves its output byte-identical to today's.
    if let generics {
      context["generic"] = true
      context["generics"] = generics.enumerated().map { index, name in
        ["name": name, "last": index == generics.count - 1]
      }
    }
    return mustache.render(context)
  }

  /// The template method entries for the interface at `id`, in declaration
  /// order — each a `name`, a `params` list, and (for a value-returning method)
  /// a `returns` clause — decoded with the owner's `generics` names threaded so
  /// a `VAR` spells its declared name.
  ///
  /// Each method's parameters, bound by the method's `Id`, drop the return
  /// pseudo-parameter (`Sequence == 0`); the rest decode their type from their
  /// own signature position. The return decodes to `returns` unless it is the
  /// spec's `void` spelling or undecodable, when `{{#returns}}` renders
  /// nothing.
  private borrowing func methods(of id: Value, _ routines: Routines,
                                 search: Array<String>,
                                 generics: Array<String>?, in dialect: Dialect,
                                 language: Language) throws
      -> Array<Dictionary<String, Any>> {
    let plan =
        try Shell.statement(Shell.query(named: "methods", search: search))
    let rows = try session.run(plan, routines, bindings: ["parent": id])
    var methods = Array<Dictionary<String, Any>>()
    methods.reserveCapacity(rows.count)
    for method in rows {
      let selection = try Shell.statement(Shell.query(named: "params",
                                                   search: search))
      let params = try session.run(selection, routines,
                                   bindings: ["parent": method[0]])
      let kept = params.filter { $0[2] != .integer(0) }
      let types = kept.map {
        session.storage.decode(parameter: $0[0].integer, generics: generics,
                               for: dialect) ?? ""
      }
      let parameters = Shell.parameters(kept.map(\.[1].text), types: types)
      var entry: Dictionary<String, Any> = [
        "name": method[1].text,
        "params": parameters,
      ]
      let returned = session.storage.decode(return: method[0].integer,
                                            generics: generics, in: dialect)
      if let returned, let clause = language.returned(returned) {
        entry["returns"] = clause
      }
      methods.append(entry)
    }
    return methods
  }

  /// The template parameter dictionaries for a method's kept parameters — one
  /// per `(name, type)` pair, in order — with each blank name assigned a
  /// stable, collision-free `local` and the trailing entry's `last` flag set.
  ///
  /// A blank parameter name (`func Foo(_ : T)`) is allowed in a protocol
  /// requirement's decl, but the wrapper's forwarding method must PASS it by
  /// name in the call (`base.Foo(arg0)`), so a blank name synthesizes a `local`
  /// used in BOTH the forwarding method's parameter list (`_ arg0: T`) and the
  /// call — while `name` stays blank in the requirement. The synthetic name is
  /// chosen AFTER the method's real names are known: it is the first `arg<N>`
  /// (from `N == 0`) not already used by a real parameter or an earlier
  /// synthetic one, so `Foo(_ : T, _ arg0: T)` gives the blank a `local` of
  /// `arg1` rather than colliding with the real `arg0`. A named parameter's
  /// `local` is its own name.
  internal static func parameters(_ names: Array<String>,
                                  types: Array<String>)
      -> Array<Dictionary<String, Any>> {
    // The names in play — the real ones plus each synthetic as it is minted —
    // so a synthetic never duplicates a real name or a sibling synthetic.
    var used = Set(names.filter { !$0.isEmpty })
    var next = 0
    var parameters = Array<Dictionary<String, Any>>()
    parameters.reserveCapacity(names.count)
    for (name, type) in zip(names, types) {
      let local: String
      if name.isEmpty {
        while used.contains("arg\(next)") { next += 1 }
        local = "arg\(next)"
        used.insert(local)
        next += 1
      } else {
        local = name
      }
      parameters.append([
        "name": name,
        "local": local,
        "type": type,
        "last": false,
      ])
    }
    // The trailing parameter's `last` flag drives the template's
    // `{{^last}}, {{/last}}` comma separation, omitting the final comma.
    if !parameters.isEmpty {
      parameters[parameters.count - 1]["last"] = true
    }
    return parameters
  }

  /// The ordered declared generic-parameter names of the interface at `id`,
  /// through the `generics` view bound by its `Id` — an empty list for a
  /// non-generic interface.
  ///
  /// A metadata file with no generic types omits the `GenericParam` table
  /// entirely (the `#~` valid mask sets a table's bit only when it has rows),
  /// so the `generics` view over it would resolve no relation; the base table's
  /// presence is checked first (`opened` is `nil` for an absent table), so a
  /// file with no generics is simply no generics rather than a faulting query.
  private borrowing func declarations(of id: Value, _ routines: Routines,
                                      search: Array<String>) throws
      -> Array<String> {
    if session.storage.opened("GenericParam") == nil { return [] }
    let clause =
        try Shell.statement(Shell.query(named: "generics", search: search))
    let declared = try session.run(clause, routines, bindings: ["parent": id])
    return declared.map(\.first!.text)
  }

  /// The text of the Mustache template named `name` — an inline template
  /// `.template` registered when `templates` carries one, else loaded through the
  /// search path (a `-I` directory's `Templates/<name>.mustache`) then the
  /// bundled `Resources/Templates/<name>.mustache`.
  ///
  /// An inline template shadows a file of the same name, so `.template com '…'`
  /// overrides the bundled `com` for the session. Otherwise the render's
  /// presentation tier is a named resource, not a literal: `com` is the one
  /// bundled template (the `@com` protocol shape), and adding a target later is
  /// dropping in another `.mustache` beside it — or shadowing one through a `-I`
  /// directory — no code change. A name no inline template, search directory, and
  /// bundle resolves raises `RenderError.template`.
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
  internal borrowing func template(named name: String,
                                   search: Array<String>) throws -> String {
    if let inline = templates[name] { return inline }
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

  /// The box-table column headers for the row-producing statement `text`, sized
  /// to its result `rows` — or `nil` when `text` is not row output (a `CREATE
  /// VIEW`), so the caller prints nothing.
  ///
  /// The headers come from the query's RESOLVED result schema
  /// (`columns(of:validate:)`), the same derivation `information_schema` and
  /// `.schema` share — so a plain `SELECT` (or a `SELECT *`) over base tables
  /// headers its REAL column names (view-shadows-table, joins, unions), and a
  /// zero-row result still frames those names with the right width. The derive
  /// is `validate: false`: the run above already proved the query runnable, so
  /// a data-dependent-empty result whose reachable projection a validating
  /// resolve would fault (`SELECT Name + 1 … WHERE …`) still frames.
  ///
  /// A `WITH`'s trailing query resolves against the statement's CTEs — the
  /// derivation keeps them in scope (`columns(of statement:)` builds a
  /// schema-only CTE overlay), so a `SELECT *` or any reference to a CTE
  /// headers what the run produced, not a same-named base relation: `WITH
  /// TypeDef(x) AS (…) SELECT * FROM TypeDef` headers `x`, the one CTE column,
  /// even though a six-column base `TypeDef` exists. Only a statement the derive
  /// still cannot resolve falls back to the trailing query's SYNTACTIC
  /// projection — an explicit list names its columns, a `SELECT *` carries none
  /// and frames by the produced width (`column N`). An unparsable string
  /// likewise frames by the produced width.
  internal borrowing func headers(of text: String,
                                  _ rows: Array<Array<Value>>)
      -> Array<String>? {
    guard let statement = try? Statement(parsing: text) else {
      return Headers.generic(rows)
    }
    if case .create = statement { return nil }
    if case .function = statement { return nil }
    // Prefer the resolved result schema (real names for a plain/base/empty
    // query, and a WITH's CTE-scoped trailing query); fall back to the trailing
    // query's syntactic projection (`SQLShell.Headers`) only when the derive
    // cannot resolve it.
    if let columns = try? session.columns(of: statement,
                                          routines: session.functions,
                                          validate: false) {
      return columns.map(\.name)
    }
    return Headers.syntactic(of: statement, rows)
  }

  /// Parses `text` as a row-producing statement, returning its `Statement`.
  ///
  /// The render's queries are static, well-formed row producers — a plain
  /// `SELECT` or a `WITH` whose trailing query is one (`requires` resolves a
  /// reference's scope chain through a recursive CTE) — so a parse failure or a
  /// non-producing statement (a `CREATE`) is a programming error and surfaces as
  /// the thrown error. A `Statement` is returned rather than a bare
  /// `SQLEngine.Query` so the `run(_:routines:bindings:)` Statement overload
  /// keeps a `WITH`'s CTEs in scope for its trailing query; a plain `SELECT`
  /// runs identically through it.
  private static func statement(_ text: String) throws -> SQLEngine.Statement {
    let parsed = try SQLEngine.Statement(parsing: text)
    switch parsed {
    case .select, .with:
      return parsed
    case .create, .function, .explain:
      throw SQLError.incomplete(expected: "a query")
    }
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

