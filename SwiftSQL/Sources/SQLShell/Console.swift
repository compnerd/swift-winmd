// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

internal import class Foundation.FileHandle
internal import struct Foundation.Data
internal import struct Foundation.URL

// MARK: - Metacommand

/// A `.`-meta-command — one of the shell's verbs that is not a SQL statement.
///
/// A statement whose leading token begins with `.` is a meta-command;
/// `Console.execute` looks up the `Metacommand` type whose `spelling` matches
/// that token and runs it against the console. Each command is one
/// self-contained type: the compiler enforces the `spelling`/`init`/`execute`
/// trio, so adding a command later is a new conformer plus one line in
/// `Console.commands`. Anything that is not a `.`-statement is SQL.
public protocol Metacommand {
  /// The leading token this command answers to, including the `.` — e.g.
  /// `".read"`.
  static var spelling: String { get }

  /// Builds the command from `arguments`, the rest of the statement after the
  /// spelling token.
  init(_ arguments: Substring)

  /// Runs the command against `console`. A throw aborts the statement; `Quit`
  /// throws the loop's stop sentinel.
  func execute(against console: inout Console) throws
}

/// `.schema <query>` — print a query's result columns (name and type) without
/// running it, resolving the query the way a run would but opening no cursor.
public struct Schema: Metacommand {
  public static let spelling = ".schema"

  /// The query text whose result columns to describe.
  private let query: String

  public init(_ arguments: Substring) {
    query = arguments.trimmed.statement.trimmed
  }

  public func execute(against console: inout Console) throws {
    if query.isEmpty { throw Console.MetaError.unknown(Schema.spelling) }
    let parsed = try Statement(parsing: query)
    for column in try console.database.columns(of: parsed, validate: true) {
      print("\(column.name)\t\(column.type.domain)")
    }
  }
}

/// `.help` — print the command summary.
public struct Help: Metacommand {
  public static let spelling = ".help"

  public init(_ arguments: Substring) {}

  public func execute(against console: inout Console) throws {
    print(Console.help)
  }
}

/// `.quit` — leave the shell. `execute` throws `Console.Stop`, the sentinel the
/// loop catches to break.
public struct Quit: Metacommand {
  public static let spelling = ".quit"

  public init(_ arguments: Substring) {}

  public func execute(against console: inout Console) throws {
    throw Console.Stop()
  }
}

/// `.read <path>` — run a file of `;`-separated SQL statements.
public struct Read: Metacommand {
  public static let spelling = ".read"

  /// The file path, the rest of the statement after `.read`.
  private let path: String

  public init(_ arguments: Substring) {
    path = arguments.trimmed
  }

  public func execute(against console: inout Console) throws {
    if path.isEmpty { throw Console.MetaError.unknown(Read.spelling) }
    try console.read(path)
  }
}

/// `.bind <name> <value>` — bind (or clear) a `:name` parameter the shell
/// threads into every SQL statement it runs. The value is typed as an
/// `.integer` when it parses as an `Int`, else `.text` (a surrounding
/// single-quote pair stripped and a doubled `''` unescaped to one `'`). A
/// `.bind` with a name and no value removes that binding.
public struct Bind: Metacommand {
  public static let spelling = ".bind"

  private let name: String
  private let value: Value?

  public init(_ arguments: Substring) {
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

  public func execute(against console: inout Console) throws {
    if name.isEmpty { throw Console.MetaError.unknown(Bind.spelling) }
    if let value {
      console.bindings[name] = value
      note("bound :\(name) = \(value.display)")
    } else {
      console.bindings[name] = nil
      note("cleared :\(name)")
    }
  }
}

// MARK: - Console

/// The standalone SQL shell — a `sqlite3`-style REPL over an in-memory
/// `Database`.
///
/// `Console` owns the mutable `database` (the session's registered views and
/// functions) and the `.bind` parameters, and is the single place execution
/// lives. `execute(_:)` runs one statement: a `.`-prefixed one is a
/// `Metacommand` looked up in `commands`; anything else is SQL run through
/// `Database.run` (a `CREATE VIEW`/`CREATE FUNCTION` registers, a `SELECT`
/// yields rows) whose rows print as a `.mode box` table. It is an escapable
/// value — the in-memory `Database` borrows nothing.
public struct Console {
  /// The shell's mutable catalog state.
  public var database: Database

  /// The `:name` parameters `.bind` has set, threaded into every SQL statement.
  public var bindings: Bindings = [:]

  /// Whether a statement fault ends the run (an explicit batch) or is reported
  /// to stderr and skipped (the interactive/redirected shell).
  private let strict: Bool

  /// Opens a shell over a fresh in-memory session. `strict` defaults to the
  /// forgiving shell policy; an explicit batch passes `true`.
  public init(strict: Bool = false) {
    database = Database()
    self.strict = strict
  }

  /// The registry of meta-commands — `execute(_:)` matches a leading `.`-token
  /// against each type's `spelling`.
  private static var commands: Array<any Metacommand.Type> {
    [Schema.self, Help.self, Quit.self, Read.self, Bind.self]
  }

  /// The command summary `.help` prints.
  public static let help = """
    .schema <query>   print a query's result columns without running it
    .read <path>      run a file of `;`-separated SQL statements
    .bind <name> <v>  bind a `:name` parameter (no value clears it)
    .help             show this help
    .quit             leave the shell
    <sql>             run a SQL statement (trailing `;` optional)
    """

  /// The sentinel `Quit.execute` throws to stop the loop — caught by the
  /// driving `for`-in, never surfaced to the user.
  public struct Stop: Error {}

  /// A fault a meta-command raises.
  public enum MetaError: Error, Equatable {
    /// An unrecognised or malformed `.`-command (the offending token).
    case unknown(String)
  }

  /// The `.`-meta spellings whose single-quoted body spans lines — none here
  /// (the standalone shell has no inline-template command), so a `Statements`
  /// stream over a console yields every `.`-meta whole.
  public static let multiline: Set<String> = []

  /// Runs one yielded `statement`. A `.`-prefixed statement is a meta-command;
  /// anything else is SQL run through `Database.run` with the console's
  /// `bindings`, its rows printed as a `.mode box` table.
  public mutating func execute(_ statement: String) throws {
    guard statement.first == "." else {
      let text = statement.statement
      let rows = try database.run(text, bindings: bindings)
      guard let names = headers(of: text, rows) else { return }
      print(Box.render(names, rows))
      return
    }
    let spelling = statement.prefix { !$0.isWhitespace }
    let arguments = statement.dropFirst(spelling.count)
    guard let command =
        Console.commands.first(where: { $0.spelling == spelling })
    else { throw MetaError.unknown(statement) }
    try command.init(arguments).execute(against: &self)
  }

  /// Runs one statement under the run's error policy — the single place that
  /// policy lives. `.quit`'s `Stop` always propagates; any other fault
  /// propagates when `strict` and is otherwise reported to stderr and swallowed.
  public mutating func attempt(_ statement: String) throws {
    do {
      try execute(statement)
    } catch let error where !(error is Stop) {
      if strict { throw error }
      note("error: \(error)")
    }
  }

  /// Runs the `;`-separated SQL statements in the file at `path` — the `.read`
  /// meta-command, each statement under the run's policy.
  public mutating func read(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let text = String(decoding: data, as: UTF8.self)
    for statement in Statements(of: text, multiline: Console.multiline) {
      try attempt(statement)
    }
  }

  /// The box-table column headers for the row-producing statement `text`, sized
  /// to `rows` — or `nil` when `text` defines rather than produces rows (a
  /// `CREATE VIEW`/`CREATE FUNCTION`). It prefers the resolved result schema
  /// (real names for a plain/empty query and a `WITH`'s CTE-scoped trailing
  /// query), falling back to the query's syntactic projection.
  internal func headers(of text: String,
                        _ rows: Array<Array<Value>>) -> Array<String>? {
    guard let statement = try? Statement(parsing: text) else {
      return Headers.generic(rows)
    }
    if case .create = statement { return nil }
    if case .function = statement { return nil }
    if let columns = try? database.columns(of: statement, validate: false) {
      return columns.map(\.name)
    }
    return Headers.syntactic(of: statement, rows)
  }
}

// MARK: - Diagnostics

/// Writes `message` and a newline to standard error — the shell's out-of-band
/// channel for a note or an error, kept off stdout so a redirected result stays
/// clean.
internal func note(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
