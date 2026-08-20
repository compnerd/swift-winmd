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

  /// The parsed render queries memoised by name for the span of one render (see
  /// `Cache`). Each `Render/<name>.sql` is loaded and parsed once per render,
  /// then reused on every interface a `.render *` emits rather than re-loaded
  /// and re-parsed per call. Each top-level render clears the memo first
  /// (`queries.statements.removeAll()`), so a `-I`/`CREATE VIEW` override edited
  /// between renders is re-resolved on the next render rather than served stale
  /// from a shell-lifetime cache — while a `:parent`/`:name` binding still
  /// varies per execution, so only the parse is shared, changing no result.
  private let queries = Cache()

  /// A batch decode bucketed by owning row `Id` — the `.render *` maps that
  /// replace a per-owner query (`roster` for an interface's methods,
  /// `signatures` for a method's parameters): each owner `Id` maps to the rows
  /// its own per-owner query would return, in the same order.
  private typealias Buckets = Dictionary<Int, Array<Array<Value>>>

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
  /// bundled `Resources/Render/*.sql` queries (not Swift literals): the seed
  /// (`seeds`) scans the interface `TypeDef` rows the `interfaces` query names —
  /// the one named interface, or every one for `*` — and fetches each `iid`
  /// through the seekable `guid` query rather than materialising the whole
  /// `interfaces` view, then for each its `methods` bound by the interface's
  /// `Id`, each method's `params` bound by the method's `Id`, and its `bases`
  /// bound by the interface's `Id`. The presentation tier is the named
  /// template loaded from `Resources/Templates`. A single interface no seed
  /// resolves raises `RenderError.interface`; a missing template resource
  /// raises `RenderError.template`.
  ///
  /// The base inheritance is derived through the `bases` view (the interface's
  /// `InterfaceImpl` rows navigated to their base type names); a rootless
  /// interface defaults to the spec's COM `root`, save the root interface
  /// itself, which inherits nothing. Identifier escaping comes from the
  /// template's language spec (the `SANITIZE` UDF), and the no-value return is
  /// decided in Swift (`returned(_:)`) — neither is baked into the binary.
  internal borrowing func render(_ interface: String,
                                 template: String) throws -> String {
    // Scope the parsed-query memo to this single render: clear it so every
    // named query re-resolves its resource once here — picking up a `-I`
    // `Render/<name>.sql`/`Queries/<name>.sql` override (or a `CREATE VIEW`)
    // added or edited since the last render — then is reused within this
    // render. The within-render dedup (the reason the memo exists — the `*`
    // batch parses each query once) survives; only cross-render staleness,
    // where an override edited between renders was silently ignored while
    // templates and language specs reloaded, is dropped.
    queries.statements.removeAll()
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
    // The rows to render come from the seed scan bound by `:name`: the one
    // named interface, or — for `*` — every one. `seeds` scans the interface
    // `TypeDef` rows directly and fetches each `iid` through the seekable `guid`
    // query, dropping a guid-less interface, so it reproduces the `interfaces`
    // view's rows without materialising the whole view. Choosing which rows to
    // emit is the seed's job, so render just iterates whatever it returns.
    // The `*` batch reads raw tables and the `interfaces` view, bypassing the
    // overridable per-node render queries (`methods`/`params`/`bases`/`guid`)
    // and the `methods`/`params`/`bases` views they read. When any of those is
    // overridden — a `-I` file or a session `CREATE VIEW` — the batch would
    // ignore the override and `*` would diverge from `.render <interface>`, so
    // `*` falls back to the per-node emit (which honours both override layers).
    // A LATERAL batch that honoured the override was rejected: `:parent` lives
    // inside the views, LATERAL cannot correlate a parameter, and a view-body
    // LATERAL does not decorrelate. Overriding and rendering `*` is rare, so
    // the fallback's per-node cost is acceptable; with nothing overridden the
    // fast batch stands.
    let batched = interface == "*" && !overridden(search: search)
    let interfaces = try seeds(interface, routines, search: search,
                               batch: batched)
    guard interface == "*" || !interfaces.isEmpty else {
      throw RenderError.interface(interface)
    }

    let mustache = try MustacheTemplate(string: body)
    // For `*` with nothing overridden, decode every interface's first plain
    // base, its methods, and every method's parameters once
    // (`inherits`/`roster`/`signatures`), bucketed by owner Id, rather than a
    // `bases`/`methods` query per interface and a `params` query per method; a
    // concrete render emits one interface, so it stays per-node. The maps only
    // supply the same base name and method/parameter rows the per-node queries
    // would — the batch rows carrying raw names the emitted-only `sanitized` map
    // escapes below — so the emit is otherwise unchanged. When a batch-shortcut
    // query or view is overridden, the maps are `nil` so `emit` runs the
    // per-node queries, honouring the override. An empty seed skips them too: a
    // wildcard that matched no interface emits nothing, and these batches expand
    // views over `InterfaceImpl`/`MethodDef`/`Param` a valid interface-free file
    // may omit, so decoding them would fault where there is nothing to render.
    let expand = batched && !interfaces.isEmpty
    let inherits = expand ? try self.inherits(routines) : nil
    let roster = expand ? try self.roster(routines) : nil
    let signatures = expand ? try self.signatures(routines) : nil
    // The batch scans carry raw names; escape only the emitted set through the
    // active `SANITIZE` UDF in one query, keyed raw→escaped, so the emit spells
    // an emitted name exactly as the per-node `SANITIZE(Name)` would while a
    // custom UDF is never invoked on a non-emitted name. `nil` in the per-node
    // path, whose `methods`/`params` queries `SANITIZE` their own rows.
    let sanitized: Dictionary<String, String>?
    if let roster, let signatures {
      sanitized = try self.sanitized(interfaces, roster: roster,
                                     signatures: signatures, routines)
    } else {
      sanitized = nil
    }
    var sources = Array<String>()
    sources.reserveCapacity(interfaces.count)
    for found in interfaces {
      sources.append(try emit(found, through: mustache, routines: routines,
                              in: dialect, language: language, search: search,
                              inherits: inherits, roster: roster,
                              signatures: signatures, sanitized: sanitized))
    }
    return sources.joined(separator: "\n")
  }

  /// Renders the transitive closure of the interface named `root` and its plain
  /// (`spec IS NULL`) base and required interfaces — the E1 edges — through the
  /// named Mustache template.
  ///
  /// The setup is the flat render's: the template names its target language, and
  /// the render resolves against the language spec's UDFs merged with the
  /// session's routines. The root selection is the same `seeds` scan the flat
  /// render uses, so a name no interface bears raises `RenderError.interface`; a
  /// simple name borne by more than one namespace seeds each match. From each
  /// seed the walk visits
  /// the base and required interfaces depth-first, emitting a base before the
  /// interface that refines it, rendering each interface once (dedup by its local
  /// `TypeDef` Id). The per-interface body is the one `emit` the flat render
  /// runs, so the closure reuses the decode and emit rather than duplicating it.
  internal borrowing func render(closure root: String,
                                 template: String) throws -> String {
    // Scope the parsed-query memo to this single render (see the flat render):
    // clear it so each named query re-resolves its resource once, honouring an
    // override edited since the last render, then is reused within this one.
    queries.statements.removeAll()
    var body = try self.template(named: template, search: search)
    let language = Shell.language(declaredIn: &body, search: search)
    let routines = language.routines.merging(session.functions)
    let dialect = language.dialect
    let roots = try seeds(root, routines, search: search)
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

  /// Whether any render query or view the `.render *` batch shortcuts is
  /// overridden — a `-I` file over one of them, or a session `CREATE VIEW` of
  /// one of their names. When true, `.render *` abandons the batch (which reads
  /// raw `MethodDef`/`Param`/`InterfaceImpl` and the `interfaces` view) for the
  /// per-node emit, so it honours the override exactly as `.render <interface>`
  /// does; when false the fast batch stands.
  ///
  /// The batch bypasses the per-node `methods`/`params`/`bases`/`guid` render
  /// queries AND the `methods`/`params`/`bases` views those queries read, so an
  /// override of any of them makes the batch and per-node paths diverge: a `-I`
  /// directory carrying `Render/<name>.sql` (a render query) or
  /// `Queries/<name>.sql` (a view), or a session `CREATE VIEW` of a view name.
  /// The `interfaces` view is a batch shortcut too — `guids` reads it while the
  /// per-node path reads `Render/guid.sql` — so its override counts as well.
  /// Only these specific names trip the predicate: an unrelated `-I` directory
  /// or a `CREATE VIEW myhelper` does not, so a session with no relevant
  /// override keeps the fast batch.
  private borrowing func overridden(search: Array<String>) -> Bool {
    // A `-I` file over a batch-shortcut render query, shadowing the bundle.
    // `interfaces` is the seed query itself: the batch assumes the stock
    // interface-only seed, so overriding it (to name a type the bundled
    // `interfaces` view's flag gate drops but the ungated per-node `guid.sql`
    // resolves) must fall `*` back to per-node too.
    for name in ["methods", "params", "bases", "guid", "interfaces"]
    where Shell.shadowed(name, "sql", kind: "Render", search: search) {
      return true
    }
    // A `-I` file over a batch-shortcut view, shadowing the bundle.
    for name in ["methods", "params", "bases", "interfaces"]
    where Shell.shadowed(name, "sql", kind: "Queries", search: search) {
      return true
    }
    // A session `CREATE VIEW` of a batch-shortcut view name — a user override
    // of the bundled view, told from the seed by `session.authored`.
    for name in ["methods", "params", "bases", "interfaces"]
    where session.authored.contains(name) {
      return true
    }
    return false
  }

  /// Whether a search directory carries `<name>.<ext>` of the given `kind` — a
  /// `-I` override shadowing the bundle, checked the same last-first way
  /// `resource(_:_:kind:search:)` resolves it, but reporting only whether a
  /// search dir (not the bundle) has it: a search-dir hit is the override the
  /// `.render *` batch fallback keys off.
  private static func shadowed(_ name: String, _ ext: String, kind: String,
                               search: Array<String>) -> Bool {
    for directory in search.reversed() {
      let path = "\(directory)/\(kind)/\(name).\(ext)"
      if FileManager.default.fileExists(atPath: path) { return true }
    }
    return false
  }

  /// The seed rows for `name` — the interface `TypeDef` rows the render
  /// `interfaces` query scans — resolved to the full render row shape (`Id`,
  /// namespace, name, `iid`), dropping an interface whose `GuidAttribute`
  /// resolves nothing.
  ///
  /// The scan seeks the interface `TypeDef` rows by name (`interfaces.sql`), and
  /// the `iid` is fetched separately so a concrete seed does not materialise the
  /// whole `interfaces` view (a three-way UNION over the whole `CustomAttribute`
  /// table): the view's `:name` predicate does not push into it, so it
  /// GUID-decodes every interface before filtering. A concrete seed fetches only
  /// the matched interface's IID through the seekable `guid` query; `*`, which
  /// needs them all, decodes them in one batch over the `interfaces` view
  /// (`guids`) rather than a `guid` query per interface. Either way, dropping a
  /// guid-less interface reproduces the view's INNER-join membership exactly — a
  /// `tdInterface` `TypeDef` with no decodable `GuidAttribute` is absent and so
  /// is not rendered — and the scan's `ORDER BY Id` preserves the view's
  /// ascending-`Id` row order, so the emitted set and its order stay
  /// byte-identical.
  private borrowing func seeds(_ name: String, _ routines: Routines,
                               search: Array<String>, batch: Bool = true) throws
      -> Array<Array<Value>> {
    let selection = try statement(named: "interfaces")
    let rows = try session.run(selection, routines,
                               bindings: ["name": .text(name)])
    // For `*`, decode every interface's `iid` in one batch over the `interfaces`
    // view rather than a `guid` query per interface. The view is the same
    // three-arm `GuidAttribute` union in the same arm order and yields one row
    // per interface `Id`, so a lookup here returns exactly the iid a per-
    // interface `guid` query's `.first` would — the emit set and order still
    // come from the `interfaces` scan above (`ORDER BY Id`). A concrete seed
    // stays per-node: it seeks one interface, not the whole view. When `batch`
    // is false — an override makes the batch and per-node paths diverge, so `*`
    // falls back to per-node — each `iid` is fetched through the per-interface
    // `guid` query, which honours a `Render/guid.sql` override the batch view
    // read would bypass. An empty scan skips the batch entirely: with no
    // interface `TypeDef` to render there is no `iid` to look up, and expanding
    // the `interfaces` view (a three-way UNION over `CustomAttribute`/
    // `MemberRef`) would fault on a valid file that omits a relation the view
    // reads but a file with no interfaces need not carry.
    let iids = name == "*" && batch && !rows.isEmpty
             ? try guids(routines) : nil
    var interfaces = Array<Array<Value>>()
    interfaces.reserveCapacity(rows.count)
    for row in rows {
      let iid = if let iids { iids[row[0].integer] }
                else { try guid(of: row[0], routines, search: search) }
      guard let iid else { continue }
      interfaces.append([row[0], row[1], row[2], .text(iid)])
    }
    return interfaces
  }

  /// Every interface's `iid`, keyed by its `TypeDef` `Id`, decoded in one batch
  /// over the `interfaces` view — the `.render *` path's replacement for a
  /// per-interface `guid` query.
  ///
  /// The view is the same three-arm `GuidAttribute` union in the same arm order
  /// the per-interface `guid` query walks, and it yields one row per interface
  /// (one iid per `Id`), so a lookup here returns exactly the iid that query's
  /// `.first` would — decoding all interfaces once instead of thousands of
  /// times. The first iid per `Id` is kept (defensively, though the view's Ids
  /// are already distinct), matching the per-interface `.first`.
  private borrowing func guids(_ routines: Routines) throws
      -> Dictionary<Int, String> {
    let batch = try Shell.statement("SELECT Id, iid FROM interfaces")
    let rows = try session.run(batch, routines, bindings: [:])
    var iids = Dictionary<Int, String>(minimumCapacity: rows.count)
    for row in rows where iids[row[0].integer] == nil {
      iids[row[0].integer] = row[1].text
    }
    return iids
  }

  /// Every interface's first plain (`TypeRef`/`TypeDef`) base interface name,
  /// keyed by its `TypeDef` `Id`, decoded in one batch — the `.render *` path's
  /// replacement for the per-interface `bases` query.
  ///
  /// It mirrors the two plain (`spec IS NULL`) arms of the `bases` view over
  /// every `InterfaceImpl` at once, in the same arm order (a `TypeRef` base
  /// before a `TypeDef` one), keeping the first base per interface `Id` —
  /// exactly the `bases.first` the per-interface render query yields. A generic
  /// (`TypeSpec`) base is excluded here as the render's `spec IS NULL` excludes
  /// it there, so the emitted inheritance is unchanged. `i.Class` is the
  /// interface's own 1-based `Id` (a simple index, stored directly).
  private borrowing func inherits(_ routines: Routines) throws
      -> Dictionary<Int, String> {
    let batch = try Shell.statement("""
      SELECT i.Class AS parent, b.TypeName AS base
      FROM InterfaceImpl i JOIN TypeRef b ON i.Interface_TypeRef = b.Id
      UNION
      SELECT i.Class AS parent, d.TypeName AS base
      FROM InterfaceImpl i JOIN TypeDef d ON i.Interface_TypeDef = d.Id
      """)
    let rows = try session.run(batch, routines, bindings: [:])
    var inherits = Dictionary<Int, String>(minimumCapacity: rows.count)
    for row in rows where inherits[row[0].integer] == nil {
      inherits[row[0].integer] = row[1].text
    }
    return inherits
  }

  /// Every method's parameters, keyed by its `MethodDef` `Id`, decoded in one
  /// batch — the `.render *` path's replacement for the per-method `params`
  /// query.
  ///
  /// It projects the same `Id`, raw `Name`, and `Sequence` the per-method render
  /// query reads — over the whole `Param` table at once, bucketed by the owning
  /// `MethodDef` in table (declaration) order — so a method's parameter list
  /// here is identical, row for row, to what its own `params` query returns. As
  /// with `roster`, the name is raw, not `SANITIZE`d: this batch scans every
  /// parameter, including those of methods `.render *` never emits, so escaping
  /// is deferred to `sanitized(_:roster:signatures:_:)` over the emitted names
  /// only. The return pseudo-parameter (`Sequence = 0`) rides along and is
  /// dropped by the caller's filter, exactly as in the per-method path; a `Param`
  /// row's `Id` is the signature position the caller decodes the type from.
  private borrowing func signatures(_ routines: Routines) throws -> Buckets {
    let batch = try Shell.statement("""
      SELECT MethodDef, Id, Name, Sequence
      FROM Param
      """)
    let rows = try session.run(batch, routines, bindings: [:])
    var signatures = Buckets()
    for row in rows {
      signatures[row[0].integer, default: []].append([row[1], row[2], row[3]])
    }
    return signatures
  }

  /// Every interface's methods, keyed by its `TypeDef` `Id`, decoded in one
  /// batch — the `.render *` path's replacement for the per-interface `methods`
  /// query.
  ///
  /// It projects the same `Id` and raw `Name` the per-interface render query
  /// reads — over the whole `MethodDef` table at once, bucketed by the owning
  /// `TypeDef` in table (declaration) order — so an interface's method list here
  /// is identical, row for row, to what its own `methods` query returns. The
  /// name is deliberately raw, not `SANITIZE`d: the per-node `methods` query
  /// runs the UDF over its (emitted-only) rows, but this batch scans every
  /// method, including methods of types `.render *` never emits — so escaping is
  /// deferred to `sanitized(_:roster:signatures:_:)`, which runs the active UDF
  /// over only the emitted names. A method's `Id` is the signature the caller
  /// decodes its return and parameters from.
  private borrowing func roster(_ routines: Routines) throws -> Buckets {
    let batch = try Shell.statement("""
      SELECT TypeDef, Id, Name
      FROM MethodDef
      """)
    let rows = try session.run(batch, routines, bindings: [:])
    var roster = Buckets()
    for row in rows {
      roster[row[0].integer, default: []].append([row[1], row[2]])
    }
    return roster
  }

  /// The raw→escaped name map for exactly the emitted interfaces' method and
  /// parameter names — the `.render *` batch's single application of the active
  /// `SANITIZE` UDF, run over only the names that will be emitted.
  ///
  /// The batch `roster`/`signatures` scans carry raw names, so the UDF never
  /// runs over a method or parameter of a type `.render *` does not emit (a
  /// class, a guid-less interface). A session `CREATE FUNCTION SANITIZE` (or a
  /// language-spec UDF) that is value-sensitive — one that would fault on such a
  /// non-emitted name — therefore no longer aborts the render. The emitted names
  /// are each emitted interface's methods (from `roster`) and those methods'
  /// non-return (`Sequence != 0`) parameters (from `signatures`), deduped and
  /// escaped through the same `routines` the per-node path resolves (a session
  /// `CREATE FUNCTION SANITIZE` included), so an emitted name's escape is
  /// byte-identical to the per-node path's. `interfaces` is the post-guid-drop
  /// emitted set (`seeds`), so a guid-less interface — dropped in Swift — is
  /// absent here even though its `TypeDef` bears the interface flag. An empty
  /// emitted set runs no query.
  private borrowing func sanitized(_ interfaces: Array<Array<Value>>,
                                   roster: Buckets, signatures: Buckets,
                                   _ routines: Routines) throws
      -> Dictionary<String, String> {
    var names = Set<String>()
    for found in interfaces {
      for method in roster[found[0].integer] ?? [] {
        names.insert(method[1].text)
        for parameter in signatures[method[0].integer] ?? []
        where parameter[2] != .integer(0) {
          names.insert(parameter[1].text)
        }
      }
    }
    guard !names.isEmpty else { return [:] }
    // One `SELECT n, SANITIZE(n) FROM (VALUES …) AS t(n)` over the deduped
    // emitted names — sorted for a deterministic query text — so the UDF runs
    // exactly once per distinct emitted name. A name is a SQL string literal,
    // so a contained `'` is doubled.
    let tuples = names.sorted().map { "(\(Shell.literal($0)))" }
        .joined(separator: ", ")
    let batch = try Shell.statement(
        "SELECT n, SANITIZE(n) FROM (VALUES \(tuples)) AS t(n)")
    let rows = try session.run(batch, routines, bindings: [:])
    var map = Dictionary<String, String>(minimumCapacity: rows.count)
    for row in rows { map[row[0].text] = row[1].text }
    return map
  }

  /// `text` as a single-quoted SQL string literal, a contained `'` doubled — so
  /// a name spliced into a `VALUES` list stays one literal.
  private static func literal(_ text: String) -> String {
    var quoted = "'"
    for character in text {
      if character == "'" { quoted += "''" } else { quoted.append(character) }
    }
    quoted += "'"
    return quoted
  }

  /// The interface `iid` the `TypeDef` at `id` bears through its
  /// `GuidAttribute`, decoded through the seekable `guid` query keyed by the
  /// interface's `Id` — the same three attribute encodings the `interfaces` view
  /// spells its `iid` through, but seeking `CustomAttribute.Parent_TypeDef`
  /// rather than materialising the whole view. `nil` when the interface bears no
  /// decodable `GuidAttribute`, the signal the seed drops it to match the view's
  /// INNER-join membership.
  private borrowing func guid(of id: Value, _ routines: Routines,
                              search: Array<String>) throws -> String? {
    let query = try statement(named: "guid")
    let rows = try session.run(query, routines, bindings: ["parent": id])
    return rows.first.map { $0[0].text }
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
    let query = try statement(named: "requires")
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
                              search: Array<String>,
                              inherits: Dictionary<Int, String>? = nil,
                              roster: Buckets? = nil,
                              signatures: Buckets? = nil,
                              sanitized: Dictionary<String, String>? = nil)
      throws -> String {
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
                                   language: language, roster: roster,
                                   signatures: signatures, sanitized: sanitized)
    // The interface's named base, via the `bases` view bound by its `Id`. The
    // render query projects only the plain (`TypeRef`/`TypeDef`) bases, whose
    // simple `TypeName` is keyword-escaped here the way the interface's own
    // name is; a generic (`TypeSpec`) base is resolved by the `bases` view
    // but omitted from the render, pending the WinRT generic-inheritance
    // projection redesign. A rootless interface defaults to the spec's COM
    // root, except the root interface itself — which inherits nothing, so it
    // never becomes its own base; an empty `root` applies no default.
    // The first plain base name: from the batch `inherits` map for `*`, else a
    // per-interface `bases` query (the concrete/closure seed). Both yield the
    // same first `spec IS NULL` base — the batch mirrors the two plain arms of
    // the `bases` view in the same arm order — so the emitted inheritance stays
    // byte-identical.
    let inherited: String? = if let inherits {
      inherits[id.integer]
    } else {
      try session.run(statement(named: "bases"), routines,
                      bindings: ["parent": id]).first?[0].text
    }
    let base: String? = if let inherited {
      language.escape(inherited)
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
                                 language: Language,
                                 roster: Buckets? = nil,
                                 signatures: Buckets? = nil,
                                 sanitized: Dictionary<String, String>? = nil)
      throws -> Array<Dictionary<String, Any>> {
    // The batch scans (`roster`/`signatures`) carry raw names escaped through
    // the emitted-only `sanitized` map; the per-node queries `SANITIZE` their
    // own rows, so their names arrive already escaped. `escaped` bridges the
    // two: it looks a name up in the batch map (present iff batching), else
    // returns it unchanged — so a per-node name is spelled as-is and a batch
    // name is escaped exactly as the per-node `SANITIZE(Name)` would spell it.
    func escaped(_ raw: String) -> String {
      sanitized.map { $0[raw] ?? raw } ?? raw
    }
    // The interface's methods: from the batch `roster` map for `*`, else a
    // per-interface `methods` query. Both return the same `Id`/`Name` rows in
    // the same (declaration) order, so the emitted method list is unchanged.
    let rows = if let roster {
      roster[id.integer] ?? []
    } else {
      try session.run(statement(named: "methods"), routines,
                      bindings: ["parent": id])
    }
    var methods = Array<Dictionary<String, Any>>()
    methods.reserveCapacity(rows.count)
    for method in rows {
      // The method's parameters: from the batch `signatures` map for `*`, else
      // a per-method `params` query. Both return the same rows in the same
      // (declaration) order, so the decoded parameter list is unchanged.
      let params = if let signatures {
        signatures[method[0].integer] ?? []
      } else {
        try session.run(statement(named: "params"), routines,
                        bindings: ["parent": method[0]])
      }
      let kept = params.filter { $0[2] != .integer(0) }
      let types = kept.map {
        session.storage.decode(parameter: $0[0].integer, generics: generics,
                               for: dialect) ?? ""
      }
      let parameters = Shell.parameters(kept.map { escaped($0[1].text) },
                                        types: types)
      var entry: Dictionary<String, Any> = [
        "name": escaped(method[1].text),
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
    let clause = try statement(named: "generics")
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

  /// The parsed render query named `name`, memoised in `queries`: on the first
  /// request within a render it loads the resource (a `-I` directory's
  /// `Render/<name>.sql` then the bundle) and parses it, and on every later one
  /// in that render it returns the cached `Statement`. A `.render *` runs each
  /// query once per interface — thousands of times — yet the text never changes
  /// within a render, so re-loading and re-parsing it per call was pure
  /// repetition; the parse now happens once per name per render. The memo is
  /// cleared at the start of each top-level render, so a resource edited between
  /// renders is re-resolved rather than served stale. Only the parse is shared:
  /// each execution still binds fresh `:parent`/`:name` values, so the memo
  /// changes no result.
  private borrowing func statement(named name: String) throws
      -> SQLEngine.Statement {
    if let cached = queries.statements[name] { return cached }
    let parsed = try Shell.statement(Shell.query(named: name, search: search))
    queries.statements[name] = parsed
    return parsed
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

/// A per-render memo of parsed render queries, keyed by name. A reference type
/// so a `borrowing` render method populates it (and clears it at each render's
/// start) through the reference; it holds only value-type `Statement`s,
/// borrowing none of the database storage, so a `~Escapable` `Shell` may own it.
private final class Cache {
  /// The parsed render queries loaded so far, keyed by name.
  var statements: Dictionary<String, SQLEngine.Statement> = [:]
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

