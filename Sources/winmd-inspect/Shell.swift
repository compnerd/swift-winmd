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

  /// Whether the current render nests — the `--closure` walk emits a nested
  /// type's enclosing containers, so an inheritance clause spells a nested base
  /// through its enclosing path (`Outer.IChild`). A flat render (`.render *`,
  /// `.render <interface>`) emits every interface at the top level and nests
  /// nothing, so a nested base must spell by its bare leaf — the top-level
  /// declaration it resolves against — not an enclosing path with no container.
  private let mode = Mode()
  /// The namespace-qualification sets the render keys off — the ambiguous
  /// `TypeName`s the decode spells qualified and the value-type `TypeDef` `Id`s
  /// the emit wraps in a namespace `enum` — memoised for the shell's lifetime
  /// (see `Storage.collisions()`). They are a pure function of the immutable
  /// database, so unlike the per-render `queries` memo they are computed once on
  /// first use and reused across every render.
  private let ambiguities = Ambiguities()

  /// A batch decode bucketed by owning row `Id` — the `.render *` maps that
  /// replace a per-owner query (`roster` for an interface's methods,
  /// `signatures` for a method's parameters): each owner `Id` maps to the rows
  /// its own per-owner query would return, in the same order.
  private typealias Buckets = Dictionary<Int, Array<Array<Value>>>

  /// The `.render *` batch of each interface's first plain base, keyed by its
  /// `Id` — the base's `TypeName` and, non-zero only when the base is a nested
  /// local definition, its `TypeDef` `Id` — so the batch spells a nested base
  /// through its enclosing path exactly as the per-interface `bases` query
  /// makes the closure.
  private typealias Inherits = Dictionary<Int, (name: String, id: Int)>

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
    /// Two or more distinct local protocols (interfaces or delegates) of the
    /// one simple `name`, borne by the listed `namespaces`, would emit as bare
    /// top-level declarations — a duplicate, uncompilable clash. A protocol
    /// cannot nest in a namespace `enum` the way a value type disambiguates, so
    /// the render rejects the closure rather than emit two `public protocol
    /// <name>`; the request must name one qualified.
    case ambiguous(String, Array<String>)
    /// A fabricated namespace `enum` container of `name` — a CLR namespace
    /// segment of an ambiguous value type the render wraps — collides with an
    /// emitted top-level declaration of that same `name`, two `public`
    /// declarations Swift rejects as a redeclaration. Only a value type can be
    /// namespace-wrapped to disambiguate, so a namespace segment that shadows
    /// an emitted protocol or bare type has no fallback; the render rejects the
    /// closure rather than emit the clash.
    case collision(String)
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
    // A flat render nests nothing, so a nested base spells by its bare leaf.
    mode.nesting = false
    // The flat render emits only the requested interface (or, for `*`, every
    // interface) — never the value-type declarations a signature names, and
    // never the fabricated namespace `enum` containers a closure wraps an
    // ambiguous value type in. So it must not namespace-qualify a value-type
    // reference: a qualified `A.Point` would name a container this render does
    // not emit. Qualification is a closure-render concern (which both qualifies
    // and emits the container); the flat render spells every value type bare,
    // through empty qualification sets.
    ambiguities.sets = ([], [])
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
  /// A type a signature spells, recorded during the walk for the frontier
  /// reservation: the emitting node (`owner`), the reference's top-level
  /// spelling (`label`), the local `TypeDef` `id` it resolves to (nil for an
  /// external referent or the synthesized fallback root), whether it is that
  /// `fallback` root, and the signature `categories` it occupies — a parameter,
  /// return, field, or inheritance base. The reservation reserves the reference
  /// only when the selected template renders one of its categories, so a
  /// reference omitted by the template neither contends nor shadows, and two
  /// same-named references in different sections do not credit each other.
  private struct Spelled {
    let owner: Int
    let label: String
    let id: Int?
    let fallback: Bool
    let categories: Set<Surface.Category>
  }

  internal borrowing func render(closure root: String,
                                 template: String) throws -> String {
    // Scope the parsed-query memo to this single render (see the flat render):
    // clear it so each named query re-resolves its resource once, honouring an
    // override edited since the last render, then is reused within this one.
    queries.statements.removeAll()
    // The closure nests, so a nested base spells through its enclosing path.
    mode.nesting = true
    // Each render fixes its own qualification sets: a closure restricts them to
    // its reached declarations (below), so a set an earlier render memoised — a
    // flat render's empty sets, or a different root's reached ones — must not
    // leak into this one.
    ambiguities.sets = nil
    var body = try self.template(named: template, search: search)
    let language = Shell.language(declaredIn: &body, search: search)
    let routines = language.routines.merging(session.functions)
    let dialect = language.dialect
    let roots = try seeds(root, routines, search: search)
    guard !roots.isEmpty else { throw RenderError.interface(root) }

    let mustache = try MustacheTemplate(string: body)
    // The types already walked, keyed on their local `TypeDef` Id, so the
    // mutually referential type graph terminates and each is visited once. The
    // walk gathers each reachable type's row and records its spelled-reference
    // edges, but defers rendering a body: the qualification sets a body is
    // spelled through are not fixed until the reached set is known (after the
    // prune), so emitting happens below, once, over the kept nodes.
    var visited = Set<Int>()
    var nodes = Array<Array<Value>>()
    var edges = Dictionary<Int, Array<Int>>()
    // Every spelled reference — a type a signature names or an interface's
    // named base — as its emitted top-level spelling paired with the local
    // `TypeDef` `Id` it resolves to (`nil` for an external reference that
    // resolves to no local row). A reference is a *frontier* — a name the
    // closure spells but does not emit — exactly when that `Id` is absent from
    // the emitted set, computed once below from the emitted-set complement:
    // this needs no per-reason enumeration, so a runtime class, a GUID-less
    // shape, a `known`-bridged or layout-rejected value type, a metadata-nested
    // protocol, a value type under a non-container, and an external reference
    // all fall out of the one rule. The spelling is the `known` bridge name
    // where one applies (so a reached value type of that bridge name contends),
    // else the reference's arity-stripped top-level component.
    var spelled = Array<Spelled>()
    // Declarations to reject: a method or field naming a by-value type nested
    // beneath a generic encloser (`Outer``1.Inner`) has no valid unqualified
    // spelling, and rendering it as the dialect's opaque pointer would silently
    // change the declaration's ABI layout — a by-value struct is not a pointer —
    // so the whole containing declaration is dropped rather than misrendered.
    var poisoned = Set<Int>()
    for seed in roots {
      try walk(seed, visited: &visited, into: &nodes, edges: &edges,
               spelled: &spelled, poisoned: &poisoned,
               routines: routines, in: dialect,
               language: language, search: search)
    }
    // Prune orphan nodes: keep only a type reachable from the seeds through
    // declarations the closure actually renders. A frontier — a metadata-nested
    // protocol, or a value type whose enclosing chain is not an emitted
    // container — is not emittable, so its own dependencies do not propagate,
    // and a type reached only through it is dropped rather than rendered as an
    // unreferenced orphan (which can fault collision checks). The enclosing
    // chain of a kept nested type is kept too, so its container survives.
    let kept = try prune(nodes, edges: edges, poisoned: poisoned,
                         seeds: roots.map { $0[0].integer })
    // Render each kept node's body in the post-order the walk gathered them, so
    // a dependency precedes the type naming it and `nest` can fold the flat
    // sequence into its containment tree.
    func render() throws -> Array<Emission> {
      var emissions = Array<Emission>()
      for node in kept {
        let body = try emit(node, through: mustache,
                            routines: routines, in: dialect,
                            language: language, search: search)
        // The top-level types this body actually declares as code — comments,
        // string literals, and per-type boilerplate excluded. Emittedness is
        // whether the selected kind section declared *this node's* type: a
        // template whose selected section is absent (or which renders only
        // shared text) declares nothing of the node's name, so the node is an
        // unemitted frontier however non-empty its body — not a declaration the
        // collision pass may qualify or wrap.
        let declarations = Shell.declarations(in: body)
        let name = Shell.name(node, language)
        // Every *other* top-level type the body declares: a generic interface
        // or delegate renders its wrapper beside an `internal protocol
        // <name>ABI`, and a custom template may emit further helpers (a
        // `struct A` beside a `protocol IRoot`). Each is a real occupant of the
        // emitted scope, so the per-scope collision check counts it — a
        // fabricated namespace `enum` or another declaration of that name is an
        // invalid redeclaration the primary label alone would not surface. Read
        // off the rendered code, not the arity, so a `-I` template that omits
        // the ABI helper is not charged a spurious collision.
        let auxiliaries = declarations.subtracting([name])
        emissions.append(Emission(id: node[0].integer,
                                  name: name,
                                  kind: node[4].text,
                                  auxiliaries: auxiliaries,
                                  declared: declarations.contains(name),
                                  body: body))
      }
      return emissions
    }
    var emissions = try render()
    // The emitted set: the types the closure actually folds into its source —
    // what `nest` renders, which the collision tally and frontier reservation
    // key off rather than the raw pruned nodes. Two conditions, both `nest`'s:
    // the template's selected kind section actually declared the type (not
    // merely produced some non-whitespace text — a template may carry a shared
    // header comment or import outside its kind sections yet omit the
    // `struct`/`enum` section, so a reached value type of that kind renders that
    // shared text but declares nothing, and is a frontier the consumer
    // supplies), and every enclosing level is itself an emitted value-type
    // container (so a type nested under a runtime class or protocol — prune
    // keeps it reached but `nest` drops it — is not counted, and neither its
    // name nor its own references leak into the sets).
    let bodied = Set(emissions.lazy.filter(\.declared).map { $0.id })
    let leaf = Dictionary(emissions.map { ($0.id, $0.kind) },
                          uniquingKeysWith: { first, _ in first })
    // Re-prune against the declarations the template actually rendered. The
    // first prune propagated a node's references on its metadata kind, but a
    // custom template may omit an intermediate declaration (render nothing for
    // a reached `struct Point`), so a type reached only through that omitted
    // node — a `Widget` a `Point` field names — is an orphan the emitted source
    // never references; left in, it renders unattached and can fault an
    // unrelated collision. Keep a node only when the seeds reach it through
    // *bodied* nodes: an un-bodied node does not propagate its references. A
    // reached node's enclosing levels stay reachable so a nested type's
    // container survives.
    var reachable = Set<Int>()
    var worklist = roots.map { $0[0].integer }
    while let node = worklist.popLast() {
      guard reachable.insert(node).inserted else { continue }
      for level in try session.storage.nesting(of: node) {
        worklist.append(level.id)
      }
      if bodied.contains(node) {
        worklist.append(contentsOf: edges[node] ?? [])
      }
    }
    var emitted = Set<Int>()
    for id in bodied
        where try reachable.contains(id)
            && session.storage.nesting(of: id).allSatisfy({
              bodied.contains($0.id)
                  && (leaf[$0.id] == "struct" || leaf[$0.id] == "enum")
            }) {
      emitted.insert(id)
    }
    // The frontier labels: the spelling of every reference the emitted set does
    // not contain — an external reference (no resolved `Id`) or one the walk,
    // prune, or an omitting template dropped. Derived once from the emitted-set
    // complement, so a name spelled by both an emitted and a frontier type
    // still contributes its frontier bearer (the dedup a single name-set would
    // lose). Both a reached value type's contention and the fabricated
    // namespace's shadow check read this one set.
    //
    // Only a reference *owned* by an emitted declaration counts: the walk
    // records a node's references before prune decides its fate, so a node
    // prune keeps as an unemittable frontier (a value type under a runtime
    // class or protocol) has already contributed its own references. No emitted
    // source
    // spells them, so a stale label must not qualify a value type or fault a
    // fabricated namespace that shares it.
    var frontiers = Set<String>()
    // The same frontier references keyed to their owners, for the fabricated
    // namespace shadow check: whether a fabricated `enum` shadows a bare
    // reference depends on the referencing scope, so the owner is retained.
    var frontierRefs = Array<(owner: Int, label: String)>()
    // A reference is a frontier when the metadata resolution — not the rendered
    // text — says its referent is unemitted: the decode records every signature
    // reference of every emitted owner in `spelled` (its owner, resolved local
    // `Id` or nil for external, and category), so the closure keys renderedness
    // off that graph, not by re-scanning the template's output. The template
    // spells names; it does not choose which references the surface bears, so a
    // reference the metadata resolves is reserved whether or not a particular
    // template happens to spell it, and a literal identifier a template writes
    // that no signature references (a `func A()`) is never in `spelled` and
    // reserves nothing.
    // The *synthesized fallback root* (`IUnknown`) is not a frontier when a
    // *top-level* local interface of that name is emitted: the synthesized
    // `protocol IRoot: IUnknown` spells the base bare, and a bare name resolves
    // at file scope, so it binds to that co-emitted protocol and is not
    // false-shadowed. A metadata-*nested* `Outer.IUnknown` does not satisfy the
    // exemption — a bare `IUnknown` cannot resolve to it — so a closure that
    // emits one while fabricating a top-level `enum IUnknown` for an ambiguous
    // value type must keep the fallback a frontier, or the inheritance binds to
    // that enum. When none is emitted at file scope (the library root, an
    // external) the fallback stays a frontier too. The exemption is keyed on the
    // fallback flag, not the label — an *explicit* external `IUnknown` parameter
    // or base of that spelling stays a frontier and faults if it would bind to
    // the local `IUnknown` not the consumer's.
    let rooted = try !language.root.isEmpty
        && emissions.contains { emission in
          try emitted.contains(emission.id)
              && emission.name == language.escape(language.root)
              && session.storage.nesting(of: emission.id).isEmpty
        }
    for reference in spelled
        where emitted.contains(reference.owner)
            && (reference.id == nil || !emitted.contains(reference.id!))
            && !(reference.fallback && rooted) {
      frontiers.insert(reference.label)
      frontierRefs.append((reference.owner, language.escape(reference.label)))
    }
    // Fix the qualification sets over the emitted declarations alone
    // (`Storage.collisions(among:)`), so an unreachable or template-omitted
    // same-named type neither wraps nor faults a reached value type. The
    // closure emit and nest both read them through `qualifying()`, so a body is
    // spelled with the same set that nests it, and the reached-only tally is
    // shared by the two. A frontier the render spells but does not emit
    // contends too, so a reached value type of its name wraps rather than
    // capturing the frontier's reference.
    ambiguities.sets =
        try session.storage.collisions(among: emitted, contended: frontiers)
    // Re-render once the qualification sets are fixed, so an ambiguous
    // reference spells its namespace-qualified path. The first render already
    // fixed the emitted set — a body's emptiness does not depend on the
    // qualification — so this second pass runs only when the tally qualifies a
    // name.
    if !(ambiguities.sets?.ids.isEmpty ?? true) { emissions = try render() }
    // Only the emitted declarations fold into the tree; a template-omitted
    // frontier, rendered empty, is left out.
    emissions = emissions.filter { emitted.contains($0.id) }
    // A nested type is spelled fully qualified in every signature that names it
    // (`Foo.Bar`), so its declaration must actually nest under its encloser for
    // the two spellings to agree and for two same-named nested types under
    // different enclosers not to collide as duplicate top-level declarations.
    // Fold the flat post-order emission into real Swift nesting, wrapping only
    // an ambiguous value type in its fabricated namespace `enum` containers. The
    // frontier references (with owners) let `nest` fault a fabricated `enum`
    // that would shadow a bare frontier reference in its scope.
    return try nest(emissions, language: language,
                    wrapping: qualifying().ids, frontier: frontierRefs)
  }

  /// The namespace-qualification sets the render keys off for this render: the
  /// ambiguous `TypeName`s the decode spells qualified, and the value-type
  /// `Id`s the emit wraps in a namespace `enum`. The decode spelling and the
  /// emit nesting share this one source, so a reference is spelled with the
  /// same set that decides whether its container is emitted.
  ///
  /// Each render fixes the sets up front, before any emit: the closure render
  /// to its reached declarations (`Storage.collisions(among:)`), the flat
  /// render to the empty sets — it emits no value-type or container
  /// declarations, so it qualifies nothing and spells every value type bare. An
  /// unset memo therefore never reaches an emit; it defaults to the empty
  /// (bare) sets rather than qualifying against a tally no declaration backs.
  private borrowing func qualifying() -> (names: Set<String>, ids: Set<Int>) {
    ambiguities.sets ?? ([], [])
  }

  /// Keeps only the emissions reachable from the `seeds` through the emitted
  /// declarations' spelled references (`edges`), dropping the orphans a
  /// discarded frontier — or a reference the output never spells (a static
  /// field, a custom modifier) — leaves behind. An emission that cannot itself
  /// be emitted (a metadata-nested protocol, or a value type whose enclosing
  /// chain is not an emitted value-type container) is a frontier: it renders no
  /// declaration, so its own references do not propagate and a type reached
  /// only through it is dropped rather than rendered unreferenced (which can
  /// fault collision checks). The enclosing chain of a kept nested type is kept
  /// too, so the container that holds it survives.
  private borrowing func prune(_ nodes: Array<Array<Value>>,
                               edges: Dictionary<Int, Array<Int>>,
                               poisoned: Set<Int>,
                               seeds: Array<Int>) throws
      -> Array<Array<Value>> {
    var kind = Dictionary<Int, String>(minimumCapacity: nodes.count)
    for node in nodes { kind[node[0].integer] = node[4].text }
    // Whether the emission's declaration renders, so its references propagate:
    // a type — a value type, or (Swift permitting a protocol nested in a value
    // type, SE-0404) an interface/delegate reached as `Outer.IChild` — renders
    // only when every enclosing level is an emitted value-type container. The
    // test is on the chain, not the leaf's kind: a protocol nests inside a
    // `struct`/`enum` but not inside another protocol or a runtime class, and
    // it cannot itself hold a nested type — the same test `nest` applies before
    // folding a type into the tree.
    func emittable(_ id: Int) throws -> Bool {
      guard kind[id] != nil else { return false }
      return try session.storage.nesting(of: id).allSatisfy {
        kind[$0.id] == "struct" || kind[$0.id] == "enum"
      }
    }
    var kept = Set<Int>()
    var queue = seeds
    while let node = queue.popLast() {
      // A poisoned declaration (one naming a by-value type nested beneath a
      // generic encloser) is dropped entirely — never kept, never propagated —
      // rather than rendered with an ABI-changing opaque pointer.
      guard !poisoned.contains(node) else { continue }
      guard kept.insert(node).inserted else { continue }
      for level in try session.storage.nesting(of: node) {
        queue.append(level.id)
      }
      if try emittable(node) { queue.append(contentsOf: edges[node] ?? []) }
    }
    return nodes.filter { kept.contains($0[0].integer) }
  }

  /// Assembles the flat post-order `emissions` into nested Swift declarations —
  /// an ambiguous value type wrapped under the namespace `enum`s its
  /// fully-qualified spelling names, every value type nested under its enclosing
  /// types, each nested protocol dropped — so a declaration's path matches the
  /// spelling its signatures carry and two same-named types stay distinct.
  ///
  /// `ambiguous` is the set of value-type `Id`s the decode spells
  /// namespace-qualified (`Storage.collisions()`): an ambiguous top-level value
  /// type is spelled fully qualified — `Windows.Win32.Foundation.Point`,
  /// `A.B.Outer.Inner` — so its declaration must nest that deep for the two to
  /// agree, while an unambiguous one spells bare and is a plain root. The
  /// CLR-namespace segments of an ambiguous type are fabricated as real Swift
  /// `enum` namespaces above its enclosing chain: unlike a type encloser, a
  /// namespace is not a real `TypeDef`, so fabricating an `enum` per segment is
  /// sound here (a real Win32 namespace segment — `Windows`/`Win32`/… — is never
  /// itself a projected type name; a collision with an emitted type of that name
  /// is possible in principle but does not arise). The set shares one source
  /// with the decode, so a nested ambiguous type and its enclosing chain wrap
  /// together — the outermost encloser of any ambiguous type is itself in
  /// `ambiguous` — keeping the emitted path and the spelled path in agreement.
  /// A nested value type (`Foo.Bar`) nests under its immediate encloser, which
  /// must be
  /// a real emitted value-type container — an encloser this closure emitted as a
  /// `struct`/`enum`, never a fabricated namespace `enum` (a fabricated encloser
  /// would misrepresent an emitted `protocol`, which cannot hold a value type,
  /// or shadow a runtime `class` the encloser names). Each value type's
  /// enclosing chain (`storage.nesting(of:)`) is tested end to end: it nests
  /// only when every level is an emitted value-type container, so `Foo.Bar.Baz`
  /// nests only if both `Foo` and `Bar` are; a chain with any non-container
  /// level — a `protocol`, an excluded runtime `class`, or a level not emitted —
  /// makes it a dropped frontier the consumer defines.
  ///
  /// An interface or delegate emits as a Swift `protocol`, which cannot nest in
  /// any container and is never namespace-qualified: only a top-level one (an
  /// empty enclosing chain) is a legal root, spelled bare. A metadata-nested
  /// protocol is a dropped frontier — a bare top-level declaration would neither
  /// match its metadata-nested spelling nor tell two same-named nested protocols
  /// apart — so it renders nothing, exactly as a value type with an unusable
  /// enclosing chain does.
  ///
  /// The kept roots — the outermost namespace `enum`s and the top-level
  /// protocols — render in the post-order the walk emitted them (a container at
  /// its earliest-emitted descendant), so a dependency precedes the type naming
  /// it and a top-level type keeps its position. A namespace `enum`'s members
  /// keep that same earliest order; a real value-type container's nested types
  /// render in name order for determinism.
  private borrowing func nest(_ emissions: Array<Emission>,
                              language: Language,
                              wrapping ambiguous: Set<Int>,
                              frontier: Array<(owner: Int, label: String)>)
      throws -> String {
    // A node in the containment forest: a real emitted `TypeDef` (keyed by its
    // local Id) or a fabricated CLR-namespace container (keyed by its raw dotted
    // path, so every value type in that namespace shares the one container).
    enum Node: Hashable {
      case type(Int)
      case space(String)
    }
    // The rendered body, declaration name, and emission position of each emitted
    // type, keyed by its local `TypeDef` Id.
    var bodies = Dictionary<Int, String>(minimumCapacity: emissions.count)
    var declared = Dictionary<Int, String>(minimumCapacity: emissions.count)
    var index = Dictionary<Int, Int>(minimumCapacity: emissions.count)
    // The Ids emitted as value-type containers — a `struct` or `enum` — the only
    // kinds a nested type may legally nest inside.
    var container = Set<Int>()
    // The auxiliary top-level names each node's body declares beyond its label
    // — a generic type's `internal protocol <name>ABI`, or a custom template's
    // extra helper — so the per-scope collision check counts them alongside the
    // labels.
    var auxiliaries = Dictionary<Int, Set<String>>(
        minimumCapacity: emissions.count)
    for (position, emission) in emissions.enumerated() {
      bodies[emission.id] = emission.body
      declared[emission.id] = emission.name
      index[emission.id] = position
      if emission.kind == "struct" || emission.kind == "enum" {
        container.insert(emission.id)
      }
      if !emission.auxiliaries.isEmpty {
        auxiliaries[emission.id] = emission.auxiliaries
      }
    }
    // The containment forest: the roots (namespace `enum`s and top-level
    // protocols), each node's direct children. A dropped frontier is recorded
    // nowhere, so it never renders.
    var roots = Array<Node>()
    var children = Dictionary<Node, Array<Node>>()
    // The namespace nodes already linked into the forest, so a shared namespace
    // is fabricated once.
    var linked = Set<Node>()
    // Fabricates the namespace-container chain for `segments` (raw, outermost
    // first), linking each level under the previous — the outermost a root — and
    // returns the deepest node, the immediate parent of a top-level value type.
    func space(_ segments: Array<Substring>) -> Node {
      var path = ""
      var parent: Node?
      var node = Node.space("")
      for segment in segments {
        path = path.isEmpty ? String(segment) : path + "." + segment
        node = .space(path)
        if linked.insert(node).inserted {
          if let parent {
            children[parent, default: []].append(node)
          } else {
            roots.append(node)
          }
        }
        parent = node
      }
      return node
    }
    for emission in emissions {
      let chain = try session.storage.nesting(of: emission.id)
      // A type nests only when every enclosing level is an emitted value-type
      // container; any other level makes it a dropped frontier. A value type
      // nests, and — Swift permitting a protocol nested in a value type
      // (SE-0404) — so does an interface/delegate reached as `Outer.IChild`, so
      // the reference resolves to a real member rather than a phantom one. A
      // protocol cannot itself hold a nested type, so it never becomes a
      // container below.
      guard chain.allSatisfy({ container.contains($0.id) }) else {
        // A top-level protocol (or a value type with an unusable chain)
        // survives only as a root; a nested one is a dropped frontier.
        if chain.isEmpty { roots.append(.type(emission.id)) }
        continue
      }
      if let inner = chain.last {
        children[.type(inner.id), default: []].append(.type(emission.id))
      } else if container.contains(emission.id),
          ambiguous.contains(emission.id) {
        // An ambiguous top-level value type nests under its CLR-namespace
        // `enum`s, matching the namespace-qualified spelling its references
        // carry; only a value type wraps — a top-level protocol spells bare.
        let raw = try session.storage.namespace(of: emission.id)
        guard !raw.isEmpty else {
          // A value type in the global CLR namespace has no segment to
          // fabricate a container from, so its ambiguity cannot be
          // resolved: its references would stay bare and capture the
          // same-named type it
          // contends with. Reject the residual collision rather than wrap it in
          // a fabricated empty-name `enum` (a `split` of `""` yields one empty
          // segment, not none) that silently misbinds.
          throw RenderError.collision(declared[emission.id] ?? "")
        }
        let segments = raw.split(separator: ".",
                                 omittingEmptySubsequences: false)
        children[space(segments), default: []].append(.type(emission.id))
      } else {
        // A top-level protocol, or an unambiguous top-level value type that
        // spells bare, needs no fabricated namespace container: it is a plain
        // root.
        roots.append(.type(emission.id))
      }
    }
    // The declaration label of a node — a type's escaped name, or a namespace
    // segment escaped the same way the decode escapes a namespace component, so
    // the fabricated `enum` name matches the qualified spelling.
    func label(_ node: Node) -> String {
      switch node {
      case let .type(id):
        return declared[id] ?? ""
      case let .space(path):
        return language.escape(String(path.split(separator: ".").last ?? ""))
      }
    }
    // Every scope in the forest — the top-level roots and each container's
    // direct children — is one Swift declaration scope, so its members must
    // bear distinct labels: a duplicate at any level is an uncompilable
    // redeclaration, not only among the roots. Nesting can place a real value
    // type and a fabricated namespace `enum` of the one name inside the same
    // container (`enum A` holding both a real `B` and the `B` namespace of an
    // `A.B.…` type), which a root-only check misses. The first clash in
    // sorted-label order across all scopes faults, so the fault is
    // deterministic.
    // Only a type's *primary* declaration nests; `rendered` hoists its
    // file-scope header/footer (an `import`, an `extension`, or an extra `struct
    // Helper`) up through every enclosing container — a fabricated namespace
    // `enum` and a real value-type container alike — to the root file scope. So
    // a nested type's auxiliaries occupy the root scope however deep it sits,
    // not its container's: two descendants of *different* wrapped containers
    // each hoisting a same-named helper are a file-scope redeclaration a
    // per-container check would miss. Collect every *nested* type's auxiliaries
    // — every node that is a member of some container, at any depth — keyed to
    // the roots; a top-level root's own auxiliaries are counted in the roots
    // scope below.
    var hoisted = Dictionary<String, Int>()
    for (_, members) in children {
      for node in members {
        if case let .type(id) = node {
          for name in auxiliaries[id] ?? [] { hoisted[name, default: 0] += 1 }
        }
      }
    }
    var clash: (label: String, nodes: Array<Node>, redeclaration: Bool)?
    let scopes: Array<(container: Node?, members: Array<Node>)> =
        [(nil, roots)] + children.map { ($0.key, $0.value) }
    for (container, scope) in scopes {
      var byLabel = Dictionary<String, Array<Node>>()
      // Auxiliaries occupy the file scope, never a container's: every one hoists
      // to the roots (`hoisted`, seeded into that scope alone). So the roots
      // scope counts the hoisted helpers *and* each top-level root's own
      // auxiliaries — an `internal protocol <name>ABI` or a custom template's
      // extra helper — while a nested scope (a real container or a fabricated
      // `enum`) counts none of its members', which are all hoisted out.
      var auxiliary = container == nil ? hoisted : [:]
      for node in scope {
        byLabel[label(node), default: []].append(node)
        if case let .type(id) = node, container == nil {
          for name in auxiliaries[id] ?? [] { auxiliary[name, default: 0] += 1 }
        }
      }
      for (name, nodes) in byLabel where nodes.count >= 2 {
        if clash == nil || name < clash!.label { clash = (name, nodes, false) }
      }
      // An auxiliary name a real declaration (or another node's auxiliary) in
      // the same scope also bears: an invalid redeclaration the emission labels
      // alone do not surface.
      for (name, count) in auxiliary {
        let total = (byLabel[name]?.count ?? 0) + count
        if total >= 2, clash == nil || name < clash!.label {
          clash = (name, byLabel[name] ?? [], true)
        }
      }
    }
    // A signature spells a frontier reference — a type the closure names bare
    // but does not emit (a runtime class, an external or `known` type, an
    // inherited external base) — by its outermost component. Swift resolves that
    // bare identifier by walking outward from the referencing declaration's
    // scope through each enclosing scope to the top level, binding it to the
    // first member of that name it finds. So an emitted declaration or a
    // fabricated namespace `enum` of that name in ANY scope enclosing the
    // reference's owner captures it — a top-level protocol or container, the
    // fabricated segment wrapping the owner, or a *sibling* container visible
    // through a shared ancestor (the `C` of `enum A.enum C` seen from
    // `A.B.Point` through `enum A`). The bound-to type is not the consumer's, so
    // the clash faults `collision`; a protocol cannot be namespace-wrapped away
    // to avoid it. This mirrors the language's own name lookup, so it neither
    // misses a shadow a narrower check would nor faults an unrelated same-named
    // type in a scope the reference cannot see.
    var enclosing = Dictionary<Node, Node>(minimumCapacity: children.count)
    for (container, members) in children {
      for member in members { enclosing[member] = container }
    }
    // A scope's occupants are its members' spelled labels *and* every auxiliary
    // top-level name the template declares alongside them — a generic type's
    // `<name>ABI` helper, or a custom template's extra helper — so a frontier
    // reference resolving bare to any of them is shadowed just as one resolving
    // to a member declaration is. A `.space` node contributes only its own
    // segment label: its wrapped members' auxiliaries do not stay in the enum,
    // they hoist to the root file scope, so they are seeded into `top` below.
    func occupants(of node: Node) -> [String] {
      guard case let .type(id) = node else { return [label(node)] }
      return [label(node)] + (auxiliaries[id] ?? [])
    }
    // The file scope holds every root's occupants *and* every nested type's
    // hoisted helper (`hoisted`, already tallied for the redeclaration check),
    // so a frontier reference resolving bare to a hoisted helper is shadowed
    // even when its owner sits in an unrelated root subtree the outward walk
    // never reaches the helper's container from.
    let top = Set(roots.flatMap(occupants)).union(hoisted.keys)
    // A frontier reference is spelled in its owner's own declaration — the
    // metadata places it in the owner's signature, and the template spells it
    // there — so it resolves outward from the owner's nested scope: the roots,
    // each enclosing container's members, and the hoisted file-scope helpers.
    // A fabricated or emitted occupant of that name in an enclosing scope binds
    // the bare reference to the wrong type, so the render faults.
    var shadows = Set<String>()
    for reference in frontier {
      var visible = top
      var scope: Node? = .type(reference.owner)
      while let current = scope {
        for member in children[current] ?? [] {
          for name in occupants(of: member) { visible.insert(name) }
        }
        scope = enclosing[current]
      }
      if visible.contains(reference.label) { shadows.insert(reference.label) }
    }
    let shadow = shadows.min()
    if let shadow, clash == nil || shadow < clash!.label {
      throw RenderError.collision(shadow)
    }
    if let clash {
      // An auxiliary declaration (a generic type's `<name>ABI`, or a custom
      // template's extra helper) colliding with a declaration of that name is
      // always a `collision`: the helper is a fixed internal declaration, not a
      // namespace-qualifiable public type, so it never reads as `ambiguous`.
      if clash.redeclaration { throw RenderError.collision(clash.label) }
      // Same-named top-level protocols — a `.type` node that is not an emitted
      // value-type container, the one clash a namespace `enum` cannot
      // disambiguate — yield `ambiguous`, named by their namespaces. Any other
      // clash is a fabricated namespace container shadowing an emitted type
      // (only a value type can be wrapped), a `collision`; a nested `.type` is
      // always a value-type container, so a nested clash is never `ambiguous`.
      let protocols = clash.nodes.allSatisfy { node in
        if case let .type(id) = node { !container.contains(id) } else { false }
      }
      if protocols {
        let namespaces = try clash.nodes.map { node -> String in
          guard case let .type(id) = node else { return "" }
          return try session.storage.namespace(of: id)
        }
        throw RenderError.ambiguous(clash.label, namespaces.sorted())
      }
      throw RenderError.collision(clash.label)
    }
    // The earliest emission position anywhere in a node's subtree, so a
    // container sorts at its earliest-emitted descendant — a top-level type at
    // its own position, a container at its earliest-emitted member. A fabricated
    // namespace node has no position of its own.
    func earliest(_ node: Node) -> Int {
      var least = if case let .type(id) = node { index[id] ?? Int.max }
                  else { Int.max }
      for child in children[node] ?? [] { least = min(least, earliest(child)) }
      return least
    }
    // The joined non-empty parts of a rendered node — its file-scope header,
    // its declaration, and its file-scope footer, in that order.
    func join(_ parts: String...) -> String {
      parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    // A node rendered as (file-scope header, declaration, file-scope footer). A
    // type's declaration carries its nested children folded in before its
    // closing brace; a fabricated `public enum` wraps its members. But only the
    // primary *declaration* nests — a custom template may frame a type with a
    // file-scope `import` header or `extension` footer, which Swift permits
    // at file scope, so `partition` splits them off and they bubble up, through
    // every enclosing container, to the roots. This is symmetric across a real
    // `.type` container and a fabricated `.space` namespace: both fold their
    // members' declarations and hoist their members' headers/footers. A real
    // container orders its children by name; a namespace `enum` keeps its
    // members in emission (earliest) order, preserving the post-order a
    // top-level value type held before it was wrapped.
    func rendered(_ node: Node)
        -> (header: String, declaration: String, footer: String) {
      let kids = children[node] ?? []
      // Fold each child's declaration in (indented), collecting the children's
      // hoisted headers and footers to pass further up.
      func fold(_ ordered: [Node]) -> (block: String, header: String,
                                        footer: String) {
        var headers = Array<String>()
        var footers = Array<String>()
        let block = ordered.map { kid -> String in
          let parts = rendered(kid)
          if !parts.header.isEmpty { headers.append(parts.header) }
          if !parts.footer.isEmpty { footers.append(parts.footer) }
          return Shell.indent(parts.declaration)
        }.joined(separator: "\n")
        return (block, headers.joined(separator: "\n"),
                footers.joined(separator: "\n"))
      }
      switch node {
      case let .type(id):
        guard let body = bodies[id] else { return ("", "", "") }
        let own = Shell.partition(body, named: label(node))
        guard !kids.isEmpty else { return own }
        let folded = fold(kids.sorted { label($0) < label($1) })
        let declaration = Shell.inject(folded.block, into: own.declaration,
                                       container: label(node))
        return (join(own.header, folded.header), declaration,
                join(folded.footer, own.footer))
      case .space:
        let folded = fold(kids.sorted { earliest($0) < earliest($1) })
        let container = Shell.inject(folded.block,
                                     into: "public enum \(label(node)) {\n}",
                                     container: label(node))
        return (folded.header, container, folded.footer)
      }
    }
    roots.sort { earliest($0) < earliest($1) }
    return roots.map {
      let parts = rendered($0)
      return join(parts.header, parts.declaration, parts.footer)
    }.joined(separator: "\n")
  }

  /// Indents every non-empty line of `text` by one four-space level — the step
  /// a nested declaration is inset under its container. A blank line stays
  /// blank so no line carries trailing whitespace.
  private static func indent(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "    \($0)" }
        .joined(separator: "\n")
  }

  /// Splices the nested-declaration `block` into `body` just before the closing
  /// brace of `body`'s *main* declaration — the `struct` or `enum` named
  /// `container` — so a rendered container carries its nested types inside its
  /// own body. The closer, a single-line declaration's shared brace, a leading
  /// helper, a brace-delimited footer, and a brace inside a comment or string
  /// literal are all discriminated off the syntax tree; see `Surface.inject`.
  private static func inject(_ block: String, into body: String,
                             container name: String) -> String {
    Surface.inject(block, into: body, container: name)
  }

  /// Splits a value type's rendered `body` into the file-scope content before
  /// its primary declaration, the declaration itself (with its leading
  /// attributes and doc comments and its whole nested body), and the file-scope
  /// content after it. A custom template may frame the type with a file-scope
  /// `import` header or an `extension` footer, which Swift permits only at file
  /// scope; when the type is wrapped in a fabricated namespace `enum`, only the
  /// declaration is wrapped and the header and footer are hoisted back outside
  /// the enum. A bundled body — a `struct`/`enum` under only its leading doc
  /// comment — is all declaration (empty header and footer), so it wraps
  /// byte-identically. A body with no locatable `struct`/`enum` declaration of
  /// `name` is treated as all declaration. The declaration is located off the
  /// syntax tree; see `Surface.partition`.
  private static func partition(_ body: String, named name: String)
      -> (header: String, declaration: String, footer: String) {
    Surface.partition(body, named: name)
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
  /// namespace, name, `iid`, and a literal `kind` of `interface`), dropping an
  /// interface whose `GuidAttribute` resolves nothing.
  ///
  /// The `interfaces.sql` seed projects three columns (`Id`, namespace, name);
  /// the `iid` is fetched here and the `interface` kind tag appended in Swift
  /// (index 4), so the seed row carries the same kind-tagged shape the
  /// `requires`/`references` closure selections carry — `emit` and `walk` both
  /// dispatch on that `kind` — while the seed query keeps its three-column
  /// contract, unchanged for a flat render or a `-I` override.
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
      interfaces.append([row[0], row[1], row[2], .text(iid),
                         .text("interface")])
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
      -> Inherits {
    // The base's `Id` rides alongside its `TypeName`, non-NULL only when the
    // base is a nested local definition (a `NestedClass` row names it), so the
    // render spells that base through its enclosing path, exactly as the
    // per-interface path resolves it. A base named through a `TypeRef` resolves
    // to its local definition by the same scope-chain recursion `requires`
    // performs — `resolved(ref, def)` here — so a nested base named that way
    // carries its Id too; a top-level base (either arm) keeps a NULL id and
    // spells bare, and an external `TypeRef` reaches no local definition and
    // likewise spells bare.
    let batch = try Shell.statement("""
      WITH RECURSIVE resolved(ref, def) AS (
        SELECT r.Id, d.Id
        FROM TypeRef r JOIN TypeDef d
          ON d.TypeNamespace = r.TypeNamespace AND d.TypeName = r.TypeName
        WHERE r.ResolutionScope_TypeRef IS NULL
          AND r.ResolutionScope_Module IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM NestedClass nc WHERE nc.NestedClass = d.Id
          )
        UNION
        SELECT r.Id, d.Id
        FROM resolved e
          JOIN TypeRef r ON r.ResolutionScope_TypeRef = e.ref
          JOIN NestedClass nc ON nc.EnclosingClass = e.def
          JOIN TypeDef d ON d.Id = nc.NestedClass AND d.TypeName = r.TypeName
      )
      SELECT i.Class AS parent, b.TypeName AS base,
        CASE
          WHEN EXISTS (SELECT 1 FROM NestedClass nc WHERE nc.NestedClass = rv.def)
          THEN rv.def
          ELSE NULL
        END AS id
      FROM InterfaceImpl i JOIN TypeRef b ON i.Interface_TypeRef = b.Id
        LEFT JOIN resolved rv ON rv.ref = b.Id
      UNION
      SELECT i.Class AS parent, d.TypeName AS base,
        CASE
          WHEN EXISTS (SELECT 1 FROM NestedClass nc WHERE nc.NestedClass = d.Id)
          THEN d.Id
          ELSE NULL
        END AS id
      FROM InterfaceImpl i JOIN TypeDef d ON i.Interface_TypeDef = d.Id
      """)
    let rows = try session.run(batch, routines, bindings: [:])
    var inherits = Inherits(minimumCapacity: rows.count)
    for row in rows where inherits[row[0].integer] == nil {
      inherits[row[0].integer] = (row[1].text, row[2].integer)
    }
    return inherits
  }

  /// Spell an interface's plain base for its inheritance clause. A base that
  /// resolves to a local definition (`id` its `TypeDef` `Id`, non-zero) is
  /// spelled through the *same* qualification a signature naming it decodes:
  /// `Storage.spelling(of:qualifying:)` first, so a nested base whose outermost
  /// encloser is a wrapped ambiguous value type reads `A.Outer.IChild` (the
  /// wrapped path the emit nests it under) rather than the bare enclosing
  /// `Outer.IChild` that cannot resolve; falling back to the plain enclosing
  /// path when the base is not qualified. Each path component is escaped
  /// separately so a keyword encloser is delimited within the path. A top-level
  /// local `id` yields its bare name (its qualified and bare spellings being
  /// one and the same), and an external base (`id` zero, resolving to no local
  /// definition) spells by its bare escaped name.
  private borrowing func refine(_ base: String, local id: Int,
                                qualifying: Set<String>,
                                _ language: Language) throws -> String {
    guard id != 0 else { return language.escape(base) }
    // A flat render nests no enclosing container, so a nested base's enclosing
    // path (`Outer.IChild`) resolves against nothing; spell the bare leaf, the
    // top-level declaration the flat render emits it as. The closure emits the
    // encloser as a real container, so there the enclosing path resolves.
    guard mode.nesting else { return language.escape(base) }
    let path = try session.storage.spelling(of: id, qualifying: qualifying)
        ?? session.storage.qualified(of: id)
    return path
        .split(separator: ".")
        .map { language.escape(String($0)) }
        .joined(separator: ".")
  }

  /// The interface's plain bases with their resolved local Ids, run through the
  /// bundled `Render/bases.sql`. A `-I` `Queries/bases.sql` override predating
  /// the `ref`/`def` provenance columns lacks them, so the render faults on the
  /// missing column (`SQLError.column`); the fallback re-runs a legacy shape
  /// that resolves each base to a local interface *by name* — the best-effort
  /// resolution the provenance replaced — so an emitted local base keeps its Id
  /// (and is not mistaken for an external frontier) while the older override
  /// still renders rather than failing outright.
  private borrowing func heritage(of id: Value, _ routines: Routines) throws
      -> Array<Array<Value>> {
    do {
      return try session.run(statement(named: "bases"), routines,
                             bindings: ["parent": id])
    } catch let error as SQLError {
      guard case .column = error else { throw error }
      return try session.run(
          Shell.statement("SELECT b.base, (SELECT MIN(n.Id) FROM interfaces n"
              + " WHERE n.TypeName = b.base) AS id"
              + " FROM bases b WHERE b.spec IS NULL"),
          routines, bindings: ["parent": id])
    }
  }

  /// The concrete/closure inheritance base of interface `id`, resolved and
  /// spelled — the per-interface counterpart of the `.render *` batch's
  /// `inherits` map. The `bases` query names the selected plain base; the
  /// `requires` scope-chain walk resolves that name to its local definition (a
  /// nested base named through a TypeRef included), so `refine` spells a nested
  /// local base through its enclosing path. An external base (or a `-I`
  /// override's fabricated name) matches no local definition and spells bare.
  /// Nil when the interface names no plain base.
  private borrowing func inheritance(of id: Value, _ routines: Routines,
                                     qualifying: Set<String>,
                                     _ language: Language) throws -> String? {
    guard let base = try heritage(of: id, routines).first else {
      return nil
    }
    // The base's resolved local `TypeDef` Id comes from the `bases` query off
    // the InterfaceImpl provenance (zero for an external base), so `refine`
    // spells a nested local base through its enclosing path and an external one
    // bare — keyed off the resolved identity, not a name correlation that an
    // external base sharing a local nested interface's bare name would capture.
    let local = base.count > 1 ? base[1].integer : 0
    return try refine(base[0].text, local: local, qualifying: qualifying,
                      language)
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

  /// Emits the type `found` and, first, the transitive closure of every local
  /// type it depends on — a depth-first post-order, so a dependency precedes the
  /// type naming it. `found` is a kind-tagged row (`Id`, namespace, name, `iid`,
  /// and a `kind` of `interface`/`struct`/`enum`/`delegate`), the shape the
  /// `interfaces`, `requires`, and `references` selections share.
  ///
  /// The adjacency depends on the node's kind. An interface first closes over
  /// its plain (`spec IS NULL`) base and required interfaces — the E1 edges,
  /// through the `requires` query, each resolved to its local interface `TypeDef`
  /// row keyed on namespace and name — then over the value-type and delegate
  /// types its methods name (E3/E7). A struct closes over its fields' types
  /// (E6), a delegate over its `Invoke` signature (E7), and an enum is a leaf.
  /// Each signature-named type resolves through the `references` query to a local
  /// `types` row; a runtime `class` stays a frontier, and an external
  /// `TypeRef`-only reference resolves to no row and simply drops. The visited
  /// set (the local `TypeDef` Id) renders each type once across all kinds and
  /// terminates a cycle; the neighbours are walked in a stable
  /// namespace-then-name order so the emission is deterministic.
  private borrowing func walk(_ found: Array<Value>, visited: inout Set<Int>,
                              into nodes: inout Array<Array<Value>>,
                              edges: inout Dictionary<Int, Array<Int>>,
                              spelled: inout Array<Spelled>,
                              poisoned: inout Set<Int>,
                              routines: Routines, in dialect: Dialect,
                              language: Language,
                              search: Array<String>) throws {
    guard visited.insert(found[0].integer).inserted else { return }
    // A parameterised (generic) type is a WinRT projection, out of scope for
    // the pure-COM closure — its `TypeName` carries an arity suffix (`` Foo`1
    // ``). Frontier it: emit no wrapper and do not walk its members. A COM
    // interface or delegate is never generic, so this reaches only a WinRT
    // dependency; a reference to it still spells through the decode, so the
    // consumer's type satisfies the signature.
    if found[2].text.contains("`") { return }
    // Frontier a reached dependency the language import already provides — a
    // type whose Identity `(namespace, name)` is a key in the dialect's `known`
    // bridge table (`HRESULT`, `BOOL`, `PWSTR`, …): emit no wrapper for it and
    // do not walk its members, exactly as the layout-reject and nested-protocol
    // frontiers do. A reference to it still spells through `dialect.known` (its
    // bridged name), so the consumer's imported type satisfies the signature.
    // The seeds are interfaces, which the `known` table never names, so only
    // reached dependencies are frontiered here.
    if dialect.known[Identity(namespace: found[1].text,
                              name: found[2].text)] != nil {
      return
    }
    // Reject a value type whose ABI layout `@frozen` cannot reproduce — an
    // explicit layout (a union or offset-placed fields), a non-default packing,
    // or a declared class size (tail padding to a fixed extent) — rather than
    // project a wrong-sized struct: emit nothing and do not walk its fields,
    // leaving it a frontier the consumer defines. The `layout` query returns a
    // row only for such a type; a naturally-laid struct returns none and renders
    // normally. (`ClassLayout` is an optional table, resolved empty when absent,
    // so a database with no laid-out type reads no packing or size row.)
    if found[4].text == "struct",
        try session.run(statement(named: "layout"), routines,
                        bindings: ["parent": found[0]]).first != nil {
      return
    }
    // The types this node's rendered declaration spells: its base and required
    // interfaces (E1) and its signature-named value/delegate types (E3/E6/E7).
    // Recorded as its `edges` so a post-walk reachability prune can drop a type
    // reachable only through a declaration the closure discards (a frontier) as
    // an orphan that would render unreferenced and fault collision validation.
    var neighbors = Array<Int>()
    // An interface closes over its base and required interfaces first (E1),
    // before the signature-named types, so an inherited surface precedes the
    // refinement naming it.
    if found[4].text == "interface" {
      let query = try statement(named: "requires")
      let bases = try session.run(query, routines,
                                  bindings: ["parent": found[0]])
      neighbors.append(contentsOf: bases.map { $0[0].integer })
      for base in bases.sorted(by: Shell.precedes) {
        // A `requires.sql` override copied from the earlier bundled query
        // returns four columns (Id, namespace, name, iid) with no trailing
        // `kind`, which the recursion reads from `found[4]`. Render-query
        // shadowing is a supported extension point, so pad a short row to the
        // interface shape an `InterfaceImpl` base always has rather than trap.
        let resolved = base.count > 4 ? base : base + [.text("interface")]
        try walk(resolved, visited: &visited, into: &nodes, edges: &edges,
                 spelled: &spelled, poisoned: &poisoned,
                 routines: routines, in: dialect,
                 language: language, search: search)
      }
      // The rendered inheritance clause names exactly one base — the `bases`
      // view's first plain base, or the language's fallback root (`IUnknown`)
      // when there is none — which the local-only `requires` walk above may not
      // have returned even when it returned other local bases (a `bases` row
      // ordered ahead of them may be external). Record that *selected* base as
      // a spelled reference: its Id is the local base of that name `requires`
      // resolved, if any, else nil — an external base or the library root. The
      // emitted-set complement then makes it a frontier exactly when the
      // closure does not emit it, so a fabricated namespace cannot shadow
      // it and a same-named reached value type contends.
      let base = try heritage(of: found[0], routines).first
      let inherited = base?[0].text
      // The base's resolved local `TypeDef` Id, carried through the `bases`
      // query off the InterfaceImpl provenance — non-zero only for a local base,
      // never correlated by name (an external base sharing a nested interface's
      // bare `TypeName` stays external, Id 0).
      let local = base.map { $0.count > 1 ? $0[1].integer : 0 } ?? 0
      let selected: String? = if let inherited {
        inherited
      } else if !language.root.isEmpty, found[2].text != language.root {
        language.root
      } else {
        nil
      }
      if let selected {
        // The frontier label is the leading component of the base's *qualified*
        // spelling — its outermost encloser for a nested local base (the `Outer`
        // of `Outer.IChild`, which a top-level fabricated `Outer` shadows), else
        // the bare name — so the shadow check reserves the name the emitted
        // inheritance actually spells.
        let label = if local != 0 {
          try session.storage.qualified(of: local).prefix { $0 != "." }
        } else {
          selected.prefix { $0 != "." && $0 != "`" }
        }
        // The selected base's local `TypeDef` Id, non-nil only for a `bases`-
        // resolved explicit base; nil for the language's fallback root (which
        // carries no `bases` row) or an external base. The synthesized fallback
        // root — flagged so the frontier pass exempts *it* alone, not every
        // reference of the root's name — binds to a co-emitted local interface
        // of its name (a metadata `IUnknown`) not reading as a frontier;
        // which local `IUnknown` is emitted is unknown until the reached set is
        // fixed (several may share the name across namespaces), so the frontier
        // pass resolves it against the emitted set. An *explicit* reference of
        // that name stays a frontier and faults if it binds to a local
        // `IUnknown` instead of the consumer's.
        spelled.append(Spelled(owner: found[0].integer, label: String(label),
                               id: local != 0 ? local : nil,
                               fallback: inherited == nil, categories: [.base]))
      }
    }
    // The value-type and delegate types the node's signatures name (E3/E6/E7),
    // resolved to their local rows and walked before the terminal emit; every
    // name a signature references — kept or frontier — is recorded with the Id
    // it resolves to, so the emitted-set complement later tells the two apart.
    let adjacent = try adjacency(of: found, spelled: &spelled,
                                 poisoned: &poisoned, routines,
                                 in: dialect, search: search)
    neighbors.append(contentsOf: adjacent.map { $0[0].integer })
    edges[found[0].integer] = neighbors
    for neighbor in adjacent.sorted(by: Shell.precedes) {
      try walk(neighbor, visited: &visited, into: &nodes, edges: &edges,
               spelled: &spelled, poisoned: &poisoned,
               routines: routines, in: dialect,
               language: language, search: search)
    }
    // A nested type spells fully qualified through its enclosing chain
    // (`Outer.Inner`, `Outer.IChild`), so its immediate enclosing value type
    // must be emitted too — as the real `struct`/`enum` container the member
    // nests inside — even when no signature names `Outer` directly. This holds
    // for a nested value type and, Swift permitting a protocol nested in a
    // value type (SE-0404), a nested interface/delegate. Walk that
    // encloser (its own
    // walk climbs the rest of the chain); prune keeps it as a kept member's
    // enclosing level, but only if its emission exists, so it is walked, not
    // merely retained. A non-value encloser is left unwalked: a `protocol`/
    // `class` cannot hold a nested type, so the member stays a frontier the
    // prune drops.
    if let outer = try session.storage.nesting(of: found[0].integer).last {
      let plan =
          try Shell.statement(Shell.query(named: "references", search: search))
      let rows = try session.run(plan, routines,
                                 bindings: ["ref": .null,
                                            "def": .integer(outer.id)])
      if let row = rows.first,
          row[4].text == "struct" || row[4].text == "enum" {
        try walk(row, visited: &visited, into: &nodes, edges: &edges,
                 spelled: &spelled, poisoned: &poisoned,
                 routines: routines, in: dialect,
                 language: language, search: search)
      }
    }
    // The walked row, deferred for a body render once the reached-only
    // qualification sets are fixed; its local `TypeDef` Id, namespace, name,
    // and kind let `prune` and `nest` classify it and fold it under a parent.
    nodes.append(found)
  }

  /// The local `types` rows the signatures of `found` name — the node's
  /// signature-driven adjacency (E3/E6/E7). An interface contributes every type
  /// its methods name, a struct every type its fields name, a delegate the types
  /// its `Invoke` signature names; an enum contributes none. Each referenced
  /// type resolves through the `references` query — by the exact `TypeRef`/
  /// `TypeDef` row it was named through, not by name — to a local `types` row,
  /// dropping a runtime `class` (which stays a frontier) and an external
  /// `TypeRef`-only reference (which resolves to no row).
  private borrowing func adjacency(of found: Array<Value>,
                                   spelled: inout Array<Spelled>,
                                   poisoned: inout Set<Int>,
                                   _ routines: Routines, in dialect: Dialect,
                                   search: Array<String>) throws
      -> Array<Array<Value>> {
    // The referenced types, gathered from the node's method or field signatures
    // per its kind — each a `Referent` carrying the coded-index row it was named
    // through, so it resolves to a local definition by its exact Id, keyed to
    // the signature categories it occupies. A method's return names go to
    // `.returned`, its remaining names to `.parameter`; a struct's fields to
    // `.field`. A reference named across several positions accrues every
    // category, so the frontier reservation reserves it when the template
    // renders any one of them.
    var references = Dictionary<Referent, Set<Surface.Category>>()
    func record(_ method: Int) {
      // A referent named in both the return and a parameter position collapses
      // to one `Referent`, so it must carry both categories, not just the one a
      // return-vs-parameter ternary would pick — the reservation reserves it
      // when the template renders either section.
      let returned = session.storage.returned(method: method)
      let parameters = session.storage.parameters(method: method)
      for referent in session.storage.identities(method: method) {
        if returned.contains(referent) {
          references[referent, default: []].insert(.returned)
        }
        if parameters.contains(referent) {
          references[referent, default: []].insert(.parameter)
        }
      }
    }
    switch found[4].text {
    case "interface":
      let plan =
          try Shell.statement(Shell.query(named: "methods", search: search))
      let rows = try session.run(plan, routines,
                                 bindings: ["parent": found[0]])
      for row in rows { record(row[0].integer) }
    case "struct":
      let plan =
          try Shell.statement(Shell.query(named: "fields", search: search))
      let rows = try session.run(plan, routines,
                                 bindings: ["parent": found[0]])
      // Only instance fields close over their types: a static or literal field
      // (the `fdStatic` 0x10 bit) is dropped from the emitted declaration by
      // `structure`, so walking its type would enqueue a type the struct never
      // references — an orphan that renders anyway and can fault namespace or
      // collision validation on a member that was omitted. The walk applies the
      // same filter as the emit so the two agree on which fields count.
      // A `-I` override may supply the former two-column `fields` query (`Id`,
      // `Name`, no `Flags`); tolerate it rather than trapping on a missing
      // column — a field with no `Flags` counts as instance storage, the
      // pre-`Flags` behaviour a copied override expects.
      for row in rows where row.count <= 2 || row[2].integer & 0x10 == 0 {
        let field = row[0].integer
        for referent in session.storage.identities(field: field) {
          references[referent, default: []].insert(.field)
        }
      }
    case "delegate":
      let plan =
          try Shell.statement(Shell.query(named: "invoke", search: search))
      let rows = try session.run(plan, routines,
                                 bindings: ["parent": found[0]])
      for row in rows { record(row[0].integer) }
    default:
      return []
    }
    // Resolve each reference to its local row by the exact Id it names — a
    // `TypeRef` through the shared scope-chain `resolved` CTE (bound `:ref`), a
    // `TypeDef` by its Id directly (bound `:def`) — leaving the other key NULL so
    // one arm matches. A runtime `class` (a reference type, outside the value
    // closure) is dropped, as is a reference that resolves to no local row.
    let plan =
        try Shell.statement(Shell.query(named: "references", search: search))
    var neighbors = Array<Array<Value>>()
    for (reference, categories) in references {
      let (ref, def): (Value, Value) = switch reference.kind {
      case .reference: (.integer(reference.row), .null)
      case .definition: (.null, .integer(reference.row))
      }
      let rows = try session.run(plan, routines,
                                 bindings: ["ref": ref, "def": def])
      // Record this reference's emitted top-level spelling paired with the Id
      // whose emittedness decides it. The spelling is the `known` bridge name
      // where the reference bridges to an imported type — so a reached value
      // type of that bridge name contends — else its own arity-stripped leading
      // component: a nested reference's enclosing root, the name a top-level
      // fabrication would shadow. The label names that outermost component, so
      // the Id paired with it is the *outermost encloser's* — a nested
      // `A.Inner` is a frontier exactly when its root `A` is unemitted (`A` a
      // runtime class the prune keeps `Inner` under yet `nest` drops), not when
      // `Inner` itself is. A top-level reference is its own root. Whether it is
      // a frontier is left to the emitted-set complement below, so a class, a
      // GUID-less shape, a `known` or layout-rejected value type, and an
      // external reference need no per-reason branch here.
      // Key the bridge on the identity's *leaf* component, as the decode does:
      // a nested `Outer.Inner` bridged `wellknown Inner …` maps on `("",
      // "Inner")`, so the qualified dot-path would miss it and the label would
      // fall back to the root `Outer`, leaving a local `A.InnerBridge`
      // uncontended while a bare `InnerBridge` captured the reference.
      let leaf = reference.identity.name.split(separator: ".").last
          .map(String.init) ?? reference.identity.name
      let identity = Identity(namespace: reference.identity.namespace,
                              name: leaf)
      let bridge = dialect.known[identity]
      let label = String((bridge ?? reference.identity.name)
                             .prefix { $0 != "." && $0 != "`" })
      let root: Int? = if let id = rows.first?[0].integer {
        try session.storage.nesting(of: id).first?.id ?? id
      } else {
        nil
      }
      spelled.append(Spelled(owner: found[0].integer, label: label, id: root,
                             fallback: false, categories: categories))
      // A referent resolving *by value* to a `struct`/`enum` nested beneath a
      // generic encloser poisons the owner: the kind is read off the *resolved*
      // local `TypeDef`, so a value type named through a `TypeRef` (whose
      // reference row carries neither `Flags` nor `Extends`) is caught too. It
      // has no valid unqualified spelling and an opaque pointer would change
      // the by-value ABI, so the whole containing declaration drops. But a
      // reference solely behind a pointer, byref, or array (`embedded` false)
      // does not embed the layout and renders as an opaque pointer, so it
      // poisons nothing — dropping its owner would discard a declaration the
      // opaque pointer represents perfectly well.
      if reference.embedded {
        for row in rows where row[4].text == "struct" || row[4].text == "enum" {
          if try session.storage.enclosedByGeneric(of: row[0].integer) {
            poisoned.insert(found[0].integer)
          }
        }
      }
      for row in rows where row[4].text != "class" {
        // A nongeneric delegate projects an `@com` interface keyed on its static
        // GUID, so one bearing no `GuidAttribute` — no static IID — is a
        // frontier: dropped rather than emitted as a GUID-less `@com` shape. A
        // generic (parameterised) delegate legitimately bears no static IID (a
        // per-instantiation PIID), so it is kept and emitted through the generic
        // `{{#generic}}` arm (which omits `@com`), the way a generic interface is
        // kept below; it is told apart by its declared generic parameters, since
        // `guid(of:)` returns nil for both, so the nongeneric gate precedes it.
        if row[4].text == "delegate",
            try declarations(of: row[0], routines, search: search).isEmpty,
            try guid(of: row, routines, search: search) == nil { continue }
        // A nongeneric interface with no `GuidAttribute` has no static IID: its
        // `references` LEFT JOIN yields a NULL iid, which the template would
        // spell as `@com(interface: "")` — unusable source. Drop it, the way the
        // normal `interfaces` view (an INNER join on the GUID) excludes it. A
        // generic interface legitimately bears no static IID (a per-instantiation
        // PIID), so a NULL iid there is expected and the row is kept — its
        // template branch omits `@com` — distinguished by its declared generic
        // parameters, exactly as `guid(of:)` tells a parameterised delegate apart.
        if row[4].text == "interface", row[3].text.isEmpty,
            try declarations(of: row[0], routines, search: search).isEmpty {
          continue
        }
        neighbors.append(row)
      }
    }
    return neighbors
  }

  /// The static GUID the delegate `found` bears through its `GuidAttribute`,
  /// decoded through the `guid` query the way the `interfaces` view spells an
  /// interface's `iid`. A WinRT delegate is a COM interface — IUnknown plus a
  /// single `Invoke` — so `@com` needs its IUnknown-derived IID.
  ///
  /// `nil` marks a delegate the walk treats as a frontier: a parameterised
  /// delegate computes its PIID per instantiation and bears no static GUID, and
  /// a delegate carrying no `GuidAttribute` resolves nothing through the query.
  /// Either way the render drops it rather than emitting a GUID-less `@com`
  /// protocol.
  private borrowing func guid(of found: Array<Value>, _ routines: Routines,
                              search: Array<String>) throws -> String? {
    guard try declarations(of: found[0], routines, search: search).isEmpty
    else { return nil }
    let plan = try Shell.statement(Shell.query(named: "guid", search: search))
    let rows = try session.run(plan, routines, bindings: ["parent": found[0]])
    guard let row = rows.first, row[0] != .null else { return nil }
    return row[0].text
  }

  /// The stable namespace-then-name order the walk emits siblings in, so a
  /// closure renders deterministically regardless of the order the adjacency
  /// queries (or the referenced-identity set) yield rows. The local `Id` breaks
  /// a namespace-and-name tie — two nested types share the empty namespace and
  /// may share a bare name under different enclosers, so name alone is not a
  /// total order and the emission (hence the nesting) would otherwise vary.
  private static func precedes(_ lhs: Array<Value>,
                               _ rhs: Array<Value>) -> Bool {
    (lhs[1].text, lhs[2].text, lhs[0].integer)
        < (rhs[1].text, rhs[2].text, rhs[0].integer)
  }

  /// Renders the single type `found` through `mustache`, the per-node body the
  /// flat render and the `--closure` walk both run.
  ///
  /// `found` is a kind-tagged row; its `kind` selects the template section and
  /// the context shape. An interface renders its `@com` protocol (or generic
  /// wrapper), a struct its fields, an enum its native cases, a delegate its
  /// `Invoke` signature — each under exactly one of the template's
  /// `{{#interface}}`/`{{#struct}}`/`{{#enum}}`/`{{#delegate}}` sections, so one
  /// template renders every kind. The interface context is unchanged, nested
  /// under `interface` for the sectioned closure template. A flat render
  /// (`nested` false) additionally exposes the interface's fields at the
  /// template root, the documented pre-closure behaviour a bare `{{name}}`
  /// template reads, so an inline or `-I` template written for the flat renderer
  /// keeps working. Wrapping the decode here is what lets the closure walk reuse
  /// it across kinds rather than duplicate it.
  private borrowing func emit(_ found: Array<Value>,
                              through mustache: MustacheTemplate,
                              routines: Routines, in dialect: Dialect,
                              language: Language,
                              search: Array<String>,
                              inherits: Inherits? = nil,
                              roster: Buckets? = nil,
                              signatures: Buckets? = nil,
                              sanitized: Dictionary<String, String>? = nil)
      throws -> String {
    let (key, projection): (String, Dictionary<String, Any>) =
        switch found[4].text {
    case "struct":
      ("struct", try structure(found, routines, in: dialect,
                               language: language, search: search))
    case "enum":
      ("enum", try enumeration(found, routines, in: dialect,
                               language: language, search: search))
    case "delegate":
      ("delegate", try delegation(found, routines, in: dialect,
                                  language: language, search: search))
    default:
      ("interface", try interface(found, routines, in: dialect,
                                  language: language, search: search,
                                  inherits: inherits, roster: roster,
                                  signatures: signatures, sanitized: sanitized))
    }
    // The projection renders under its own section and is exposed at the
    // template root too — the top-level context a bare `{{name}}` template
    // reads. Both the flat render and the `--closure` walk expose it the same
    // way, so a template written for one path keeps working under the other; the
    // bundled sectioned template ignores the root fields, so output is unchanged.
    var root = projection
    root[key] = projection
    return mustache.render(root)
  }

  /// The template context for the interface `found` — its `Id`, namespace, name,
  /// and `iid` decoded into the declared generics, methods, and base the
  /// `{{#interface}}` section reads. This is the interface half of `emit`, its
  /// dictionary now the value of the context's `interface` key. The `.render *`
  /// batch maps (`inherits`/`roster`/`signatures`/`sanitized`) thread through so
  /// the wildcard batch reuses this decode; each is `nil` on the per-node path.
  private borrowing func interface(_ found: Array<Value>, _ routines: Routines,
                                   in dialect: Dialect, language: Language,
                                   search: Array<String>,
                                   inherits: Inherits? = nil,
                                   roster: Buckets? = nil,
                                   signatures: Buckets? = nil,
                                   sanitized: Dictionary<String, String>? = nil)
      throws -> Dictionary<String, Any> {
    let id = found[0]
    // A pure-COM interface is never generic (a parameterised interface is a
    // WinRT projection, out of scope), so its methods decode with no generic
    // parameter names threaded.
    let methods = try self.methods(of: id, routines, search: search,
                                   generics: nil, in: dialect,
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
    // The first plain base, spelled: from the batch `inherits` map for `*`, else
    // a per-interface `bases` query (the concrete/closure seed). Both yield the
    // same first `spec IS NULL` base — the batch mirrors the two plain arms of
    // the `bases` view in the same arm order — so the emitted inheritance stays
    // byte-identical. `refine` spells it: a local base (its resolved `Id`
    // non-zero on either path) through its enclosing path — bare for a top-level
    // one, `Outer.IChild` for a nested one — an external base by its bare name.
    let qualified = qualifying().names
    let inherited: String? = if let inherits {
      if let base = inherits[id.integer] {
        try refine(base.name, local: base.id, qualifying: qualified, language)
      } else {
        nil
      }
    } else {
      try inheritance(of: id, routines, qualifying: qualified, language)
    }
    let base: String? = if let inherited {
      inherited
    } else if language.root.isEmpty || found[2].text == language.root {
      nil
    } else {
      language.root
    }
    // The interface's own name, keyword-escaped so a `protocol`-named interface
    // spells compilably.
    let name = language.escape(found[2].text)
    var context: Dictionary<String, Any> = [
      "name": name,
      "iid": found[3].text,
      "namespace": found[1].text,
      "methods": methods,
    ]
    // An absent `base` skips the template's `{{#base}}` inheritance clause.
    if let base { context["base"] = base }
    return context
  }

  /// The template context for the struct `found` — its keyword-escaped name and
  /// its fields, each a `name` and the `type` spelled at render time from its
  /// `FieldDef` signature (edge E6). The `fields` render query projects each
  /// field's already-escaped name and its `Id`, which `decode(field:)` navigates
  /// to the field's type in the target `Dialect`.
  private borrowing func structure(_ found: Array<Value>, _ routines: Routines,
                                   in dialect: Dialect, language: Language,
                                   search: Array<String>) throws
      -> Dictionary<String, Any> {
    let plan = try Shell.statement(Shell.query(named: "fields", search: search))
    let rows = try session.run(plan, routines, bindings: ["parent": found[0]])
    // Only instance fields are the struct's ABI storage. A static or literal
    // field (the `fdStatic` 0x10 bit of `FieldDef.Flags`) is not laid out in an
    // instance, so emitting it as a stored `var` would add a nonexistent field
    // and shift every following offset, corrupting a by-value native call. Enum
    // members — also static literal fields — are rendered separately
    // (`members`), so dropping the static fields here does not affect them.
    // Tolerate a `-I` override's former two-column `fields` query (no `Flags`):
    // a field with no `Flags` column counts as instance storage.
    let instances = rows.filter { $0.count <= 2 || $0[2].integer & 0x10 == 0 }
    // Each field carries a `last` flag (computed over the retained instance
    // fields) so the template's public memberwise initialiser can comma-separate
    // its parameters — the synthesised memberwise init stays internal even for a
    // public struct, so a cross-module caller could not otherwise construct it.
    //
    // A field spelled `` `self` `` — a metadata field literally named `self`,
    // the one escaped identifier that cannot also be an init parameter name —
    // takes an `aliased` collision-free `local` — reused as the parameter's
    // internal name and the assignment's right-hand side — so the init reads
    // `` init(`self` arg0:) { self.`self` = arg0 } `` rather than reusing the
    // field spelling, whose leading `self` the assignment would bind to the
    // parameter instead of the struct instance. Every other field keeps
    // `local == name`, so its parameter and assignment spell exactly as before.
    let reserved = language.escape("self")
    let names = qualifying().names
    var taken = Set(instances.map { $0[1].text })
    var next = 0
    let fields =
        instances.enumerated().map { index, row -> Dictionary<String, Any> in
      let type = session.storage.decode(field: row[0].integer, in: dialect,
                                        qualifying: names) ?? ""
      let name = row[1].text
      let aliased = name == reserved
      let local: String
      if aliased {
        while taken.contains("arg\(next)") { next += 1 }
        local = "arg\(next)"
        taken.insert(local)
        next += 1
      } else {
        local = name
      }
      return ["name": name, "local": local, "aliased": aliased, "type": type,
              "last": index == instances.count - 1]
    }
    return ["name": Shell.name(found, language), "fields": fields]
  }

  /// The template context for the enum `found` — its keyword-escaped name, the
  /// `underlying` raw-value type, a `flags` marking, and its members, each a
  /// `name` and the integer `value` from the `Constant` table. The underlying
  /// type is the `value__` field's decoded type (falling back to the dialect's
  /// `i4` spelling when it does not decode).
  ///
  /// The projection mirrors how ClangImporter imports a C enum. A regular enum
  /// becomes a native fixed-size Swift `enum` over the `underlying` type, so a
  /// change to that width is a (correct) ABI break the projection surfaces. A
  /// `[flags]` enum — one bearing a `System.FlagsAttribute`, detected through
  /// the overridable `flags` query — becomes an `OptionSet` instead: a native
  /// `enum` case is a single value and cannot name a bitmask combination
  /// (`a | b` is no `case`), while the `[flags]` contract is exactly that its
  /// members combine, so a set type is the faithful projection (the shape Clang
  /// gives an `NS_OPTIONS` C enum). The `flags` key drives that branch in the
  /// template.
  ///
  /// A Win32 enum aliases raw values — two member names for one value — which a
  /// native `enum` cannot express (`case a = 5; case b = 5` does not compile),
  /// so the native-enum members are deduplicated by value in declaration order:
  /// the first member of each distinct value is a `case` (`alias` false), and
  /// each later member sharing an already-seen value is an alias (`alias` true)
  /// carrying the `canonical` name of the case it repeats, which the template
  /// spells as a `static var` returning that case rather than a duplicate
  /// `case`. An `OptionSet` has no such constraint — its members are `static
  /// let`s, which tolerate a repeated raw value — so a `[flags]` enum keeps
  /// every member as a plain member with no aliasing.
  ///
  /// The name is carried a second time under `owner`, the enum's own type for
  /// the `Owner(rawValue: …)` an `OptionSet` member spells and the `.member` an
  /// alias returns: inside the `{{#members}}` section `{{{name}}}` binds the
  /// member's own name, so the enclosing type is looked up under a distinct key
  /// the member context does not shadow.
  private borrowing func enumeration(_ found: Array<Value>, _ routines: Routines,
                                     in dialect: Dialect, language: Language,
                                     search: Array<String>) throws
      -> Dictionary<String, Any> {
    let all = try Shell.statement(Shell.query(named: "fields", search: search))
    let fields = try session.run(all, routines, bindings: ["parent": found[0]])
    let names = qualifying().names
    // The `value__` storage field is found by its raw metadata name (column 3),
    // not the escaped `Name`: a `SANITIZE` override (an active language spec or
    // session UDF) can respell `value__`, and matching the escaped spelling
    // would then miss it and silently fall back to `i4`, emitting an enum
    // backed by a wider type (a `UInt64`) with the wrong ABI representation.
    // Column 3 is the raw (unsanitized) name; a two-column override has none,
    // so fall back to the escaped `Name` (column 1) — `value__` is no keyword.
    let underlying = fields.first {
      ($0.count > 3 ? $0[3].text : $0[1].text) == "value__"
    }
        .flatMap { session.storage.decode(field: $0[0].integer, in: dialect,
                                          qualifying: names) }
        ?? (dialect.primitives["i4"] ?? "i4")
    // A `[flags]` enum bears a `System.FlagsAttribute`; the overridable `flags`
    // query returns a row for it and none for a plain enum. A fixture missing
    // the attribute rows simply yields no row, so the enum reads as not flags.
    let mark = try statement(named: "flags")
    let flags =
        !(try session.run(mark, routines, bindings: ["parent": found[0]])
            .isEmpty)
    let plan = try Shell.statement(Shell.query(named: "members", search: search))
    let rows = try session.run(plan, routines, bindings: ["parent": found[0]])
    let name = Shell.name(found, language)
    let members = rows.map { row -> Dictionary<String, Any> in
      // `value(field:)` already formats the constant signed or unsigned per
      // its element type, so an unsigned 64-bit member with bit 63 set spells a
      // positive `UInt64` decimal the generated raw value accepts. Both arms
      // project each member as a `static let` on the stored newtype, so a
      // repeated raw value (a Win32 alias) is simply two named constants — no
      // deduplication is needed the way a native enum's `case`s would demand.
      let value = session.storage.value(field: row[0].integer) ?? "0"
      return ["name": row[1].text, "value": value]
    }
    return ["name": name, "owner": name, "underlying": underlying,
            "flags": flags, "members": members]
  }

  /// The template context for the delegate `found` — its keyword-escaped name,
  /// its static `iid`, the `params` its `Invoke` signature carries, and the
  /// `returns` that signature yields (edge E7). A WinRT delegate is a COM
  /// interface (IUnknown plus a single `Invoke`), so the projection is an
  /// `@com(interface:)` protocol carrying just `Invoke` and `@com` generates the
  /// IUnknown-based vtable from it — the same ABI-faithful shape an interface
  /// projects.
  ///
  /// The `invoke` query selects the delegate's one `Invoke` method, whose
  /// parameters and return decode exactly as an interface method's do — the
  /// return set only when it is value-carrying (`returned(_:)` yields `nil` for
  /// `void`), so `{{#returns}}` renders nothing for a `void` `Invoke`. The
  /// walk enqueues only a delegate that bears a static GUID, so `guid(of:)`
  /// resolves the same IID here.
  private borrowing func delegation(_ found: Array<Value>, _ routines: Routines,
                                    in dialect: Dialect, language: Language,
                                    search: Array<String>) throws
      -> Dictionary<String, Any> {
    let plan = try Shell.statement(Shell.query(named: "invoke", search: search))
    let invoke = try session.run(plan, routines, bindings: ["parent": found[0]])
    // A pure-COM delegate is never parameterised (a generic delegate is a WinRT
    // projection, out of scope), so its `Invoke` names no `VAR`: the signature
    // decodes with no generic names threaded.
    var params = Array<Dictionary<String, Any>>()
    var returns: String?
    if let method = invoke.first {
      let selection =
          try Shell.statement(Shell.query(named: "params", search: search))
      let raw = try session.run(selection, routines,
                                bindings: ["parent": method[0]])
      let kept = raw.filter { $0[2] != .integer(0) }
      let qualified = qualifying().names
      let types = kept.map {
        session.storage.decode(parameter: $0[0].integer, generics: nil,
                               for: dialect, qualifying: qualified) ?? ""
      }
      params = Shell.parameters(kept.map(\.[1].text), types: types)
      if let spelled =
          session.storage.decode(return: method[0].integer, generics: nil,
                                 in: dialect, qualifying: qualified) {
        returns = language.returned(spelled)
      }
    }
    var context: Dictionary<String, Any> = [
      "name": language.escape(found[2].text),
      "iid": try guid(of: found, routines, search: search) ?? "",
      "params": params,
    ]
    // A value-carrying `Invoke` renders its `-> Type`; a `void` one omits it.
    if let returns { context["returns"] = returns }
    return context
  }

  /// The keyword-escaped declaration name of the type `found` — its raw
  /// `TypeName` stripped of any CLR arity suffix, then escaped through the
  /// target language's keyword rule, the same order the interface's own name
  /// uses so a value type named for a keyword still spells compilably.
  private static func name(_ found: Array<Value>, _ language: Language)
      -> String {
    language.escape(String(found[2].text.prefix { $0 != "`" }))
  }

  /// The top-level type names `body` declares as *code* — every identifier
  /// token in a declaration position (`<keyword> <Name>`) at brace depth zero.
  /// Both the emittedness and ABI-occupant tests read the declared set off the
  /// rendered body rather than the template shape or metadata arity, so a
  /// `-I` template that omits a declaration is not credited with one, and a
  /// `<keyword> <Name>` nested inside another declaration (`struct Helper {
  /// typealias Point = … }`) declares a member, not the top-level type.
  private static func declarations(in body: String) -> Set<String> {
    Surface.declarations(in: body)
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
    let qualified = qualifying().names
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
                               for: dialect, qualifying: qualified) ?? ""
      }
      let parameters = Shell.parameters(kept.map { escaped($0[1].text) },
                                        types: types)
      var entry: Dictionary<String, Any> = [
        "name": escaped(method[1].text),
        "params": parameters,
      ]
      let returned = session.storage.decode(return: method[0].integer,
                                            generics: generics, in: dialect,
                                            qualifying: qualified)
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
  internal static func query(named name: String,
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

/// One type the `--closure` walk emitted — its rendered body tagged with the
/// local `TypeDef` `Id`, declaration name, and kind the nesting assembly folds
/// it by. A nested type is grouped under its enclosing type through the `Id`;
/// the name orders siblings within a container; the kind decides whether the
/// type is a legal value-type container a child may nest inside. It holds only
/// value types, borrowing no database storage, so a `~Escapable` `Shell` may
/// collect it.
private struct Emission {
  /// The emitted type's local `TypeDef` `Id`.
  let id: Int

  /// The type's escaped declaration name — the sibling sort key within a
  /// container.
  let name: String

  /// The type's render kind — `struct`/`enum`/`interface`/`delegate`. Only a
  /// `struct` or `enum` renders as a value-type container a nested type may
  /// legally nest inside; an `interface`/`delegate` renders as a Swift
  /// `protocol`, which cannot contain a nested type.
  let kind: String

  /// Every top-level type the body declares *other* than `name` — a generic
  /// wrapper's synthesized `internal protocol <name>ABI`, plus any auxiliary
  /// helper a custom template emits beside the primary declaration. The primary
  /// `name` does not name them, so the collision check counts each as a scope
  /// occupant, lest a co-emitted type or a fabricated namespace of that name
  /// become an invalid redeclaration. Empty for a body that declares only its
  /// primary type.
  let auxiliaries: Set<String>

  /// Whether the template's selected kind section actually declared the type —
  /// the rendered body declares a top-level type of this node's `name` as code
  /// (`Shell.declarations`). A template whose selected section is absent, or
  /// which renders only shared boilerplate or comments for this kind, declares
  /// nothing of the name, so the type is an unemitted frontier however
  /// non-empty its body.
  let declared: Bool

  /// The rendered declaration text.
  let body: String
}

/// A per-render memo of parsed render queries, keyed by name. A reference type
/// so a `borrowing` render method populates it (and clears it at each render's
/// start) through the reference; it holds only value-type `Statement`s,
/// borrowing none of the database storage, so a `~Escapable` `Shell` may own it.
private final class Cache {
  /// The parsed render queries loaded so far, keyed by name.
  var statements: Dictionary<String, SQLEngine.Statement> = [:]
}

/// The current render's mode. A reference type so a `borrowing` render method
/// sets it at each render's start and a nested helper reads it, without either
/// borrowing the database storage a `~Escapable` `Shell` cannot escape.
private final class Mode {
  /// Whether the render nests enclosing containers (the closure) or emits every
  /// interface flat at the top level (`.render`/`.render *`).
  var nesting = false
}

/// A shell-lifetime memo of the render's namespace-qualification sets
/// (`Storage.collisions()`): the ambiguous `TypeName`s the decode spells
/// qualified and the value-type `Id`s the emit wraps in a namespace `enum`. A
/// reference type so a `borrowing` render method fills it through the reference;
/// it holds only value-type sets, borrowing none of the database storage, so a
/// `~Escapable` `Shell` may own it. The sets are a pure function of the
/// immutable database, so they are computed once and never invalidated.
private final class Ambiguities {
  /// The computed sets, or `nil` until first use.
  var sets: (names: Set<String>, ids: Set<Int>)?
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

