// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQL
internal import WinMD

internal import class Foundation.FileHandle
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

  /// Opens a shell over `storage`, starting from an empty session. `strict`
  /// defaults to the forgiving shell policy; an explicit batch passes `true`.
  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage, strict: Bool = false) {
    session = Session(storage, [:])
    self.strict = strict
  }

  /// The registry of meta-commands — `execute(_:)` matches a leading `.`-token
  /// against each type's `spelling`. Adding a command is one line here. It is
  /// computed so the metatype array (not `Sendable`) is not a shared mutable
  /// global.
  private static var commands: Array<any Metacommand.Type> {
    [Tables.self, Help.self, Quit.self, Read.self]
  }

  /// The command summary `.help` prints.
  internal static let help = """
    .tables           list the database's tables
    .read <path>      run a file of `;`-separated SQL statements
    .help             show this help
    .quit             leave the shell
    <sql>             run a SQL statement (trailing `;` optional)
    """

  /// The sentinel `Quit.execute` throws to stop the loop — caught by the
  /// driving `for`-in, never surfaced to the user.
  internal struct Stop: Error {}

  /// A fault a meta-command raises.
  internal enum MetaError: Error, Equatable {
    /// An unrecognised or malformed `.`-command (the offending token).
    case unknown(String)
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

  /// Streams statements read line-by-line from `lines`.
  internal init(reading lines: @escaping () -> String?) {
    self.lines = lines
  }

  /// Streams the statements of `text`, reading its lines.
  internal init(of text: String) {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .makeIterator()
    self.lines = { lines.next() }
  }

  internal func makeIterator() -> Iterator {
    Iterator(lines)
  }

  /// The statement iterator — the `;`-accumulator over the line source.
  internal struct Iterator: IteratorProtocol {
    /// The line source the iterator pulls from.
    private let lines: () -> String?

    /// The SQL accumulated across lines, not yet closed by a `;`.
    private var pending: String

    internal init(_ lines: @escaping () -> String?) {
      self.lines = lines
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
}
