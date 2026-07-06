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
    let relations = shell.session.storage.tables
    for index in 0 ..< relations.count { print("  \(relations[index])") }
  }
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
    guard !query.isEmpty else { throw Shell.MetaError.unknown(Schema.spelling) }
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
    guard !path.isEmpty else { throw Shell.MetaError.unknown(Read.spelling) }
    try shell.read(path)
  }
}

/// The body of the single-quoted literal `text` opens with — from its first
/// `'` to the matching close, with a doubled `''` unescaped to one `'`. The
/// empty string when `text` does not open with a `'`. A run past the close (a
/// `'` not doubled) ends the body; any text after it is ignored.
internal func unquote(_ text: String) -> String {
  guard text.first == "'" else { return "" }
  var body = ""
  var index = text.index(after: text.startIndex)
  while index < text.endIndex {
    let character = text[index]
    if character == "'" {
      let next = text.index(after: index)
      // A doubled `''` is one literal `'`; a lone `'` closes the body.
      guard next < text.endIndex, text[next] == "'" else { break }
      body.append("'")
      index = text.index(after: next)
      continue
    }
    body.append(character)
    index = text.index(after: index)
  }
  return body
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
    guard !name.isEmpty else { throw Shell.MetaError.unknown(Bind.spelling) }
    if let value {
      shell.bindings[name] = value
      note("bound :\(name) = \(value.display)")
    } else {
      shell.bindings[name] = nil
      note("cleared :\(name)")
    }
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
    guard !name.isEmpty else { throw Shell.MetaError.unknown(Template.spelling) }
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
    [Tables.self, Schema.self, Help.self, Quit.self, Read.self, Render.self,
     Bind.self, Template.self]
  }

  /// The command summary `.help` prints.
  internal static let help = """
    .tables                 list the database's tables
    .schema <query>         print a query's result columns without running it
    .read <path>            run a file of `;`-separated SQL statements
    .render <iface> <tmpl>  render an interface (or `*`) through a template
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
        try Shell.select(Shell.query(named: "interfaces", search: search))
    let interfaces = try session.run(selection, routines,
                                     bindings: ["name": .text(interface)])
    guard interface == "*" || !interfaces.isEmpty else {
      throw RenderError.interface(interface)
    }

    let mustache = try MustacheTemplate(string: body)
    var sources = Array<String>()
    sources.reserveCapacity(interfaces.count)
    for found in interfaces {
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
      // The interface's own methods, decoded with its generic names, plus — for
      // a GENERIC wrapper only — the direct base's inherited methods forwarded
      // through the wrapper (see `forwarded`).
      var methods = try self.methods(of: id, routines, search: search,
                                     generics: generics, in: dialect,
                                     language: language)
      methods += try forwarded(of: id, routines, search: search,
                               generics: generics, in: dialect,
                               language: language)
      // The interface's base. A generic base named through a `TypeSpec` (a
      // `GENERICINST`, e.g. `IIterable<Element>`) is decoded first, through the
      // `specs` view (its `TypeSpec` `Id`) with the OWNER's `generics` names so
      // the clause spells the specialized base rather than a bare name; absent
      // one, the named base comes from the `bases` view (a `TypeRef`/`TypeDef`
      // simple name). A rootless interface defaults to the spec's COM root,
      // except the root interface itself — which inherits nothing, so it never
      // becomes its own base; an empty `root` applies no default.
      //
      // A generic base spells its ABI PROTOCOL (`IIterableABI<Element>`), not
      // its wrapper `struct` — the generic arm's inheritance clause is the ABI
      // protocol's, and a protocol cannot inherit a struct. A non-generic base
      // (from `bases`, a plain protocol name) needs no suffix, and neither arm
      // reaches the wrapper spelling.
      let specialized = try specialization(of: id, routines, search: search,
                                           generics: generics, in: dialect)
      let lineage =
          try Shell.select(Shell.query(named: "bases", search: search))
      let bases = try session.run(lineage, routines,
                                  bindings: ["parent": id])
      let base: String? = if let specialized {
        specialized
      } else if let inherited = bases.first {
        inherited[0].text
      } else if language.root.isEmpty || found[2].text == language.root {
        nil
      } else {
        language.root
      }
      // A generic interface's own `TypeName` carries the CLR arity suffix
      // (`IVector``1`); strip it — the decode tier strips it only for a
      // `GENERICINST` use, so the declaration name must be stripped here — so
      // the emitted name is `IVector`, its `<T>` clause supplied separately.
      // The keyword escape (`SANITIZE`) is applied HERE, on the STRIPPED name,
      // not in the `interfaces` query: escaping the suffixed name would spare a
      // generic whose stripped name is a keyword (`protocol``1` is not the
      // reserved word `protocol`), leaving `public struct protocol` to be
      // emitted. Escaping after the strip is why the query projects the raw
      // `TypeName` — the interface's own name is the one identifier the strip
      // must precede the escape for, so its escape lives in Swift, not the SQL.
      let stripped = String(found[2].text.prefix { $0 != "`" })
      let name = language.escape(stripped)
      // The ABI-protocol name is the wrapper's own name suffixed with `ABI`,
      // used for BOTH the ABI protocol's declaration and the wrapper's `base:
      // any …ABI<…>` existential. The `ABI` suffix must precede the escape (the
      // same order the base-name spelling uses): a keyword name's `<name>ABI` is
      // never itself a keyword (no Swift keyword ends in `ABI`), so escaping the
      // SUFFIXED name is a no-op yielding a plain `protocolABI` — whereas
      // escaping FIRST then appending `ABI` would splice a backtick pair into
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
      sources.append(mustache.render(context))
    }
    return sources.joined(separator: "\n")
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
    let plan = try Shell.select(Shell.query(named: "methods", search: search))
    let rows = try session.run(plan, routines, bindings: ["parent": id])
    var methods = Array<Dictionary<String, Any>>()
    methods.reserveCapacity(rows.count)
    for method in rows {
      let selection = try Shell.select(Shell.query(named: "params",
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

  /// The template method entries the GENERIC wrapper at `id` FORWARDS from its
  /// inherited base — the direct base's own methods — so the wrapper `struct`
  /// exposes the base's surface, not only its own.
  ///
  /// The non-generic arm inherits its base's requirements transitively (a
  /// `protocol IFoo: IBase` gets `IBase`'s methods for free), but the generic
  /// wrapper is a STRUCT whose `base` is an `any …ABI`: the ABI protocol chain
  /// carries the inherited requirements, yet the wrapper only forwards the
  /// methods the template is fed, so an inherited method (an `IIterable`'s
  /// `First` behind an `IVector`) would be missing. This gathers the direct
  /// base's methods and emits forwarding entries for them, decoded with the
  /// OWNER's `generics` names — correct for the standard WinRT pass-through
  /// (`IVector<Element> : IIterable<Element>`), where the base's parameter is
  /// the owner's parameter of the same name and position, so a base `VAR 0`
  /// spells the owner's `Element`.
  ///
  /// Only a GENERIC owner with a `TypeSpec` (`GENERICINST`) base that resolves
  /// to a SAME-FILE base `TypeDef` forwards: a non-generic owner (the protocol
  /// arm already inherits transitively) and a cross-file base (no local rows to
  /// walk) forward nothing.
  ///
  /// The base's methods decode with the base's `VAR i` bound to the ARGUMENT
  /// the owner instantiates the base with — the SUBSTITUTION `substitution(…)`
  /// builds by decoding the base `TypeSpec`'s arguments in the owner's
  /// context — not to the owner's own parameter of that position: `IMap<K,V> :
  /// IIterable<IKeyValuePair<K,V>>` forwards `First() -> IKeyValuePair<K, V>`,
  /// not `-> K`. The forward is transitive: it walks the whole base chain, at
  /// each level composing the substitution (decoding the next base's arguments
  /// against the current substitution) so a grandbase's `VAR j` resolves
  /// through the intervening base. A cycle is impossible in well-formed
  /// metadata (the base chain is a DAG rooted at a non-generic interface), so
  /// the walk terminates when a level has no `TypeSpec` base.
  private borrowing func forwarded(of id: Value, _ routines: Routines,
                                   search: Array<String>,
                                   generics: Array<String>?,
                                   in dialect: Dialect,
                                   language: Language) throws
      -> Array<Dictionary<String, Any>> {
    // Only the generic-wrapper arm forwards; the non-generic protocol arm
    // inherits transitively already.
    guard generics != nil else { return [] }
    var forwarded = Array<Dictionary<String, Any>>()
    // Walk the base chain from the owner, threading the substitution that binds
    // each level's `VAR i` to the owner's argument at that position. `owner` is
    // the level whose base is inherited next; `substitution` is that base's
    // `VAR` bindings in the owner's context (the owner's own `generics` at the
    // first step, since the owner's `VAR i` IS its own parameter `i`).
    var owner = id
    var substitution = generics
    while let base = try ancestor(of: owner, routines, search: search) {
      let bindings = session.storage.substitution(ofSpec: base.spec,
                                                  generics: substitution,
                                                  in: dialect)
      forwarded += try methods(of: .integer(base.type), routines,
                               search: search, generics: bindings,
                               in: dialect, language: language)
      // Compose: the next base level's arguments decode against THIS base's
      // bindings, so its `VAR j` resolves through the base to the owner.
      owner = .integer(base.type)
      substitution = bindings
    }
    return forwarded
  }

  /// The SAME-FILE base of the interface at `id` inherited through a `TypeSpec`
  /// (`GENERICINST`) base — its `TypeSpec` `Id` (`spec`) and the base's own 1-
  /// based `TypeDef` `Id` (`type`) — or `nil` when it has no such base or the
  /// base is not a same-file `TypeDef` (a cross-file `TypeRef`, whose rows are
  /// in another module). It reads the `specs` view for the base `TypeSpec`
  /// `Id`, then the base's own `TypeDef` `Id` from that spec's decoded
  /// signature. The
  /// forwarding walk needs both: the `spec` to build the substitution and the
  /// `type` to gather the base's methods and to step to the next level.
  private borrowing func ancestor(of id: Value, _ routines: Routines,
                                      search: Array<String>) throws
      -> (spec: Int, type: Int)? {
    guard session.storage.opened("TypeSpec") != nil else { return nil }
    let clause = try Shell.select(Shell.query(named: "specs", search: search))
    let specs = try session.run(clause, routines, bindings: ["parent": id])
    guard let spec = specs.first,
        let type = session.storage.base(ofSpec: spec[0].integer) else {
      return nil
    }
    return (spec[0].integer, type)
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
    guard session.storage.opened("GenericParam") != nil else { return [] }
    let clause =
        try Shell.select(Shell.query(named: "generics", search: search))
    let declared = try session.run(clause, routines, bindings: ["parent": id])
    return declared.map(\.first!.text)
  }

  /// The inheritance spelling of the interface at `id`'s closed-generic base —
  /// whose `InterfaceImpl.Interface` is a `TypeSpec` (a `GENERICINST`, e.g.
  /// `IIterable<Element>`) — or `nil` when the interface has no such base.
  ///
  /// The spelling depends on the OWNER's genericity, not merely on the base
  /// being a `TypeSpec`:
  ///
  /// - A GENERIC owner (`generics != nil`) renders the generic-wrapper arm,
  ///   whose inheritance clause is the ABI protocol's; a protocol cannot
  ///   inherit a `struct`, so the base spells its ABI PROTOCOL
  ///   `IIterableABI` — the `ABI` suffix on the base's simple name (arguments
  ///   carried as `where`-clause associated-type constraints, not in the name)
  ///   — through `decode(abi:…)`.
  ///
  /// - A NON-generic owner (`generics == nil`) renders the public `protocol …:
  ///   <base>` arm, so the base must be a PUBLIC type its public protocol may
  ///   refine — the closed specialization's own PUBLIC spelling `IBase<String>`
  ///   (a public type, its closed arguments preserved), NOT the internal
  ///   `IBaseABI` (a public protocol cannot refine an internal one, and the
  ///   closed arguments would be dropped) — through `decode(specialization:…)`.
  ///
  /// The `specs` view surfaces the base's `TypeSpec` `Id` through the
  /// `Interface_TypeSpec` join key. A metadata file with no generics omits the
  /// `TypeSpec` table entirely (the `#~` valid mask sets a table's bit only
  /// when it has rows), so the `specs` view over it resolves no relation; the
  /// base table's presence is checked first (`opened` is `nil` for an absent
  /// table), so a file with no `TypeSpec` is simply no generic base rather than
  /// a faulting query.
  private borrowing func specialization(of id: Value, _ routines: Routines,
                                        search: Array<String>,
                                        generics: Array<String>?,
                                        in dialect: Dialect) throws -> String? {
    guard session.storage.opened("TypeSpec") != nil else { return nil }
    let clause =
        try Shell.select(Shell.query(named: "specs", search: search))
    let specs = try session.run(clause, routines, bindings: ["parent": id])
    guard let spec = specs.first else { return nil }
    // A generic owner refines the base's ABI protocol; a non-generic owner
    // refines the base's public closed specialization.
    guard let generics else {
      return session.storage.decode(specialization: spec[0].integer,
                                    in: dialect)
    }
    return session.storage.decode(abi: spec[0].integer, generics: generics,
                                  in: dialect)
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
      return Shell.generic(rows)
    }
    if case .create = statement { return nil }
    if case .function = statement { return nil }
    // Prefer the resolved result schema (real names for a plain/base/empty
    // query, and a WITH's CTE-scoped trailing query); fall back to the trailing
    // query's syntactic projection only when the derive cannot resolve it.
    if let columns = try? session.columns(of: statement,
                                          routines: session.functions,
                                          validate: false) {
      return columns.map(\.name)
    }
    return Shell.names(of: Shell.trailing(statement).first.projection, rows)
  }

  /// The row-producing query of `statement` — a `select`'s query, or a `with`'s
  /// trailing query — the syntactic-projection fallback names its columns off.
  /// A `create` or a `function` never reaches here (`headers(of:)` returns `nil`
  /// for a definition first), so it maps to a defensive nameless query.
  private static func trailing(_ statement: Statement) -> SQL.Query {
    switch statement {
    case let .select(query): query
    case let .with(_, query): query
    case let .create(_, view): view.query
    case .function:
      .select(Select(projection: .all, from: nil))
    }
  }

  /// The SYNTACTIC column headers of a `projection` — the fallback for a query
  /// the resolved schema derive cannot type (a `WITH`'s trailing query over a
  /// CTE). An explicit projection names its columns from the statement (an
  /// aliased or bare column projects its name, the qualifier dropped; a
  /// computed expression with no alias falls back to a positional `column N`);
  /// a `SELECT *` carries no names, so it frames by the produced width.
  private static func names(of projection: SQL.Projection,
                            _ rows: Array<Array<Value>>) -> Array<String> {
    switch projection {
    case let .columns(list):
      list.map(\.name)
    case let .expressions(items):
      items.enumerated().map { index, item in
        item.alias ?? column(item.expression) ?? "column \(index + 1)"
      }
    case .all:
      generic(rows)
    }
  }

  /// `column N` headers for `rows`' produced width — the fallback when a column
  /// name cannot be recovered (a `SELECT *` over a join, an unresolved relation,
  /// or a non-`SELECT` row source), so a non-empty result still frames correctly.
  private static func generic(_ rows: Array<Array<Value>>) -> Array<String> {
    (0 ..< (rows.first?.count ?? 0)).map { "column \($0 + 1)" }
  }

  /// The output name of a projected `expression` — a bare column's name (the
  /// qualifier dropped), or `nil` for a computed expression that names no
  /// column, which the header derivation falls back to a positional label.
  private static func column(_ expression: Expression) -> String? {
    if case let .column(column) = expression { column.name } else { nil }
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
///
/// A `.`-meta whose single-quoted string is still OPEN (an unbalanced `'`) is
/// the one exception to the whole-line rule: it accumulates subsequent RAW lines
/// verbatim until the quote closes, yielding the whole block as one statement —
/// the shape `.template <name> '<body>'` takes, a Mustache template written
/// inline as a multiline single-quoted literal. Because the body is
/// quote-delimited DATA, `.end`, `;`, and `{{…}}` inside it are verbatim, never
/// a terminator; only a literal `'` needs doubling. The open-quote test is the
/// same quote scan `terminator(in:)` runs (`''` an escaped quote), shared as
/// `open(in:)`.
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
    /// A `.`-meta line (when no statement is pending) yields whole — unless its
    /// single-quoted string is still OPEN (an unbalanced `'`), in which case it
    /// begins a multiline meta whose subsequent RAW lines accumulate verbatim
    /// (joined with `\n`, no `;`-splitting, no per-line `.`-meta handling) until
    /// the quote closes, and the whole block yields as ONE statement; the inline
    /// `.template <name> '<body>'` command is that shape, so `.end`, `;`, and
    /// `{{…}}` inside the body are data, never a terminator. Otherwise lines
    /// accumulate until a `;` closes a statement, which yields; a trailing
    /// unterminated statement (or an unterminated multiline meta) yields at end
    /// of input — the closing `;` is optional, so a one-shot query or a file
    /// without a final terminator runs its last statement.
    internal mutating func next() -> String? {
      while true {
        // Drain any completed statement already accumulated. A chunk that is
        // only trivia — whitespace and comments, e.g. a `-- note` between two
        // `;` — carries no statement, so skip it rather than hand the parser
        // empty input.
        if let semicolon = Iterator.terminator(in: pending) {
          let statement = String(pending[..<semicolon]).trimmed
          pending = String(pending[pending.index(after: semicolon)...])
          guard Iterator.trivial(statement) else { return statement }
          continue
        }
        // Prompt before the read (the interactive shell only): a pending,
        // unterminated statement asks for its continuation; an empty or
        // trivia-only one asks for a fresh statement. A batch's hook is `nil`,
        // so it never prompts.
        prompt?(!Iterator.trivial(pending))
        guard let line = lines() else {
          // End of input: flush a final unterminated statement (the closing
          // `;` is optional), then clear `pending` so the next call stops. A
          // trivia-only tail (a trailing or standalone `-- comment`) is nothing
          // to run, so it ends the stream rather than reaching the parser.
          let statement = pending.trimmed
          pending = ""
          return Iterator.trivial(statement) ? nil : statement
        }
        // A `.`-meta line yields whole when no statement is pending — a
        // whitespace-only or comment-only line before it is trivia, so drop it
        // rather than glue the meta line onto it (a `-- note` before `.tables`
        // must not turn the meta into SQL). `.template` alone carries a single-
        // quoted (possibly multiline) body: when ITS quote is left open, keep
        // accumulating raw lines until the quote closes, then yield the whole
        // block as one statement. Every other meta yields whole, so an
        // apostrophe in an argument — a `.read /tmp/O'Brien.sql` path — is data,
        // not an unterminated literal that would swallow the following lines.
        if Iterator.trivial(pending), line.trimmed.first == "." {
          let meta = line.trimmed
          let spelling = meta.prefix { !$0.isWhitespace }
          guard spelling == Template.spelling, Iterator.open(in: meta) else {
            pending = ""
            return meta
          }
          return accumulate(meta)
        }
        pending += pending.isEmpty ? line : "\n" + line
      }
    }

    /// Accumulates the `.template` block whose single-quoted body is open,
    /// starting from `meta` (its first, trimmed line), reading RAW lines
    /// verbatim (joined with `\n`, no `;`-splitting, no per-line `.`-meta
    /// handling) until the quote closes, then yielding the whole block as one
    /// statement. End of input before the quote closes flushes what was
    /// captured — the closing `'` is as optional as a trailing `;`.
    private mutating func accumulate(_ meta: String) -> String {
      var block = meta
      while Iterator.open(in: block) {
        prompt?(true)
        guard let line = lines() else { break }
        block += "\n" + line
      }
      pending = ""
      return block
    }

    /// The index in `text` of the first `;` that terminates a statement — one
    /// outside a string literal, a delimited identifier, and a comment — or
    /// `nil` when there is none (including when `text` trails off inside an
    /// unclosed `'…'` or `"…"`). A `;` inside `'…'`, `"…"`, `--`, or `/* … */`
    /// is data, not a terminator, so the split matches what the SQL lexer
    /// scans.
    ///
    /// It runs the shared `scan`, as `open(in:)` does, so both agree on what a
    /// literal, an identifier, and a comment are.
    private static func terminator(in text: String) -> String.Index? {
      var index = text.startIndex
      var enclosure = Enclosure.none
      while index < text.endIndex {
        if Iterator.scan(text, &index, &enclosure) { continue }
        if enclosure == .none, text[index] == ";" { return index }
        index = text.index(after: index)
      }
      return nil
    }

    /// Whether `text` ends inside an unclosed single-quoted literal — a
    /// QUOTE-ONLY scan for `.template` body accumulation. Unlike the SQL
    /// `terminator` scan it does NOT skip comments or track delimited
    /// identifiers: a `.template` line is meta-command text, not SQL, so a
    /// `--`, `/*`, or `"` in its name or body is data, and only a `'…'` (a
    /// doubled `''` escaped) opens or closes the body. `false` when every `'`
    /// is balanced, so the line stands complete.
    private static func open(in text: String) -> Bool {
      var index = text.startIndex
      var quoted = false
      while index < text.endIndex {
        let character = text[index]
        if quoted {
          if character == "'" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "'" {
              index = text.index(after: next)
              continue
            }
            quoted = false
          }
        } else if character == "'" {
          quoted = true
        }
        index = text.index(after: index)
      }
      return quoted
    }

    /// The literal/identifier the scan is currently inside — none, a single-
    /// quoted string, or a double-quoted delimited identifier. A comment or a
    /// `;` terminator is recognised only in `.none`; inside a string or an
    /// identifier those bytes are data, exactly as the lexer treats them.
    private enum Enclosure: Equatable { case none, string, identifier }

    /// Advances the `enclosure` state at `index` in `text`. In `.none` it
    /// enters a string on `'` or a delimited identifier on `"`, and otherwise
    /// skips a `--` or `/* … */` comment; inside a string or identifier it
    /// consumes a doubled `''`/`""` as an escaped quote (skipping both) or
    /// closes on a lone one. Returns `true` when it already advanced `index` (a
    /// skipped pair or comment — the caller must not step again), `false` when
    /// `index` still points at the character to consider. This is the SQL scan
    /// `terminator(in:)` runs; `.template` meta text uses the quote-only
    /// `open(in:)` instead, since `--`/`"` there are data, not SQL.
    private static func scan(_ text: String, _ index: inout String.Index,
                             _ enclosure: inout Enclosure) -> Bool {
      let character = text[index]
      switch enclosure {
      case .string:
        guard character == "'" else { return false }
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "'" {
          index = text.index(after: next)
          return true
        }
        enclosure = .none
      case .identifier:
        guard character == "\"" else { return false }
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "\"" {
          index = text.index(after: next)
          return true
        }
        enclosure = .none
      case .none:
        if character == "'" {
          enclosure = .string
        } else if character == "\"" {
          enclosure = .identifier
        } else if character == "-", let end = Iterator.simple(text, index) {
          // A `--` line comment: skip to (not past) its newline, which the
          // caller advances over as ordinary text. A `;` inside it is not a
          // terminator, matching the lexer's trivia.
          index = end
          return true
        } else if character == "/", let (end, _) = Iterator.block(text, index) {
          // A `/* … */` block comment (or an unterminated `/*` run to the end):
          // skipped whole, so a `;` inside it is not a terminator either.
          index = end
          return true
        }
      }
      return false
    }

    /// The index of the newline ending a `--` line comment begun at `index` (or
    /// `endIndex`), or `nil` when `index` begins no comment (no second `-`).
    private static func simple(_ text: String, _ index: String.Index)
        -> String.Index? {
      let second = text.index(after: index)
      guard second < text.endIndex, text[second] == "-" else { return nil }
      var cursor = text.index(after: second)
      while cursor < text.endIndex, text[cursor] != "\n" {
        cursor = text.index(after: cursor)
      }
      return cursor
    }

    /// Whether `text` carries no statement — only whitespace and comments, so
    /// it lexes to no token. Such a fragment (a trailing or standalone comment,
    /// or a blank chunk between two `;`) must not be handed to the parser,
    /// which would reject it as empty input.
    private static func trivial(_ text: String) -> Bool {
      var index = text.startIndex
      while index < text.endIndex {
        let character = text[index]
        if character == "-", let end = Iterator.simple(text, index) {
          index = end
        } else if character == "/", let comment = Iterator.block(text, index) {
          // An unterminated block comment is NOT trivia: the fragment must
          // reach the parser so the lexer reports the missing `*/`, rather than
          // being silently dropped. A closed comment is skipped.
          guard comment.closed else { return false }
          index = comment.end
        } else if character.isWhitespace {
          index = text.index(after: index)
        } else {
          return false
        }
      }
      return true
    }

    /// The end of a `/* … */` block comment begun at `index` and whether it
    /// closed: the index just past its `*/` with `closed` true, or `endIndex`
    /// with `closed` false when unterminated; `nil` when `index` begins no
    /// comment (no `*` after the `/`). The `closed` flag lets `trivial` keep an
    /// unclosed comment non-trivial so its error still reaches the parser,
    /// while `scan` consumes either way.
    private static func block(_ text: String, _ index: String.Index)
        -> (end: String.Index, closed: Bool)? {
      let second = text.index(after: index)
      guard second < text.endIndex, text[second] == "*" else { return nil }
      var cursor = text.index(after: second)
      while cursor < text.endIndex {
        if text[cursor] == "*" {
          let close = text.index(after: cursor)
          if close < text.endIndex, text[close] == "/" {
            return (text.index(after: close), true)
          }
        }
        cursor = text.index(after: cursor)
      }
      return (cursor, false)
    }
  }
}

// MARK: - Session

extension Session {
  /// Runs one SQL `statement` against the session, returning the rows a
  /// `SELECT` yields — or none for a `CREATE VIEW`, which registers its `View`,
  /// or a `CREATE FUNCTION`, which registers its scalar `Function` into the
  /// session's routines (each key case-folded, the way the catalog and routines
  /// resolve it) instead. A `CREATE` is an ordinary statement here, not a
  /// special case; the shell prints whatever rows come back.
  ///
  /// `bindings` resolve a `:name` parameter of a `SELECT` or a `WITH` — the
  /// shell threads its `.bind` bindings through here, so a parameterized query
  /// typed at the prompt finds its values, whether the parameter sits in a plain
  /// `SELECT` or in a `WITH`'s body or trailing query. A `CREATE VIEW` ignores
  /// them: it stores the view's text, binding only when a later `SELECT` reads
  /// it.
  internal mutating func run(_ statement: String, bindings: Bindings = [:])
      throws -> Array<Array<Value>> {
    let parsed = try Statement(parsing: statement)
    switch parsed {
    case let .create(name, view):
      register(name, view)
      return []
    case let .function(name, function):
      try register(name, function)
      return []
    case let .select(query):
      return try self.run(query, functions, bindings: bindings)
    case .with:
      return try self.run(parsed, functions, bindings: bindings)
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
  /// COM-interface views are the one bundled set, so adding a query later is
  /// dropping in another `.sql` beside them (or under a `-I` directory) — no
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
  /// method's parameters, a `bases` view of one interface's named base type,
  /// and a `specs` view of a generic base named through a `TypeSpec`. These
  /// four carry a uniform `:parent` param — the owning row's `Id` — so a render
  /// can walk interface → methods → params, binding each level's `Id` to the
  /// next's `:parent`, and look up the interface's base by its `Id`.
  ///
  /// The `bases` view navigates the interface's single `InterfaceImpl` row
  /// (whose simple `Class` index is the interface's 1-based `Id`) to its
  /// base type's simple name, projecting `TypeRef.TypeName` as `base`. The
  /// `Class` column is a *simple* `TypeDef` index — it stores the `Id`
  /// directly, so the predicate is `i.Class = :parent` (there is no decoded
  /// `Class_TypeDef` join key — `WinMDRelation.keys` derives keys only for
  /// *coded* indices). `Interface` is the coded `TypeDefOrRef`, so its decoded
  /// `Interface_TypeRef` key equi-joins the base `TypeRef`. Both arms of the
  /// coded index resolve, `UNION`ed: a cross-file base through
  /// `Interface_TypeRef` (a `TypeRef`) and a same-file base through
  /// `Interface_TypeDef` (a `TypeDef` in this module).
  ///
  /// A generic base — an `IIterable<Element>`, whose `InterfaceImpl.Interface`
  /// is a `TypeSpec` (a `GENERICINST`), not a `TypeRef`/`TypeDef` name — has no
  /// `TypeName` to project, so `bases` cannot spell it; the `specs` view
  /// instead surfaces its `TypeSpec` `Id` through the `Interface_TypeSpec` join
  /// key, and the render decodes that signature with the owner's generic names.
  /// It is a separate view — not a `bases` `UNION` arm — because a metadata
  /// file with no generics omits the `TypeSpec` table entirely, which a
  /// `bases`-arm `JOIN TypeSpec` would fail to resolve; the render runs `specs`
  /// only when the `TypeSpec` table is present.
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
    // A double renders through Swift's default `Double` description — the
    // shortest decimal that round-trips to the same binary64 — so it is
    // lossless and keeps a `.0` on a whole value (`1.0`, not `1`), marking the
    // cell approximate-numeric rather than an integer.
    case let .double(double):   "\(double)"
    case let .text(text):       text
    case let .boolean(boolean): boolean ? "TRUE" : "FALSE"
    // A blob renders as a lowercase-hex `x'…'` literal — lowercase `x` and
    // digits, an empty blob as `x''` — the way `sqlite3` shows a BLOB cell.
    case let .blob(bytes):      "x'" + Value.hex(bytes) + "'"
    }
  }

  /// `bytes` as a lowercase-hex string — each byte two lowercase nibbles, high
  /// nibble first, so a byte's width is fixed and its leading zero is kept.
  private static func hex(_ bytes: Array<UInt8>) -> String {
    let digits = Array("0123456789abcdef")
    var hex = ""
    hex.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      hex.append(digits[Int(byte >> 4)])
      hex.append(digits[Int(byte & 0x0f)])
    }
    return hex
  }

  /// This cell's `text`, the empty string for any non-text cell — the render
  /// only ever reads `.text` columns (names, types, the IID), so a non-text
  /// cell is a NULL the caller has already filtered.
  internal var text: String {
    if case let .text(text) = self { text } else { "" }
  }

  /// This cell's `integer`, zero for any non-integer cell — the render reads a
  /// `Id`/`Sequence` `.integer` column to navigate a signature, so a
  /// non-integer cell is a NULL the query guarantees never appears there.
  internal var integer: Int {
    if case let .integer(integer) = self { integer } else { 0 }
  }
}
