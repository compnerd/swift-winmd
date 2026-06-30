// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import class Foundation.FileHandle
internal import struct Foundation.Data

internal import ArgumentParser
internal import WinMD

/// The `query` subcommand: run a SQL script against a metadata database, or —
/// given no script — open an interactive SQL shell over it (the `Shell`).
///
/// A script argument is one or many `;`-separated statements streamed through
/// `Statements(of:)` and run one at a time by `Shell.execute`: each `SELECT`
/// prints its rows tab-separated and each `CREATE VIEW` is visible to later
/// statements. With no argument, `query` opens the `sqlite3`-style shell, whose
/// statements stream through `Statements(reading: readLine)` to end of input — a
/// terminal drives it interactively, a pipe or redirect feeds it identically
/// (`winmd-inspect query db < file` is the `sqlite3 db < file` analogue). No
/// terminal detection: `readLine()` is cross-platform. Both are a literal
/// `for`-in over the statement stream. The interactive/redirected path reports
/// a statement's own error (`error: …`) to stderr and keeps reading, with only
/// `.quit`'s `Shell.Stop` breaking the loop; the explicit-argument batch stays
/// fail-fast, propagating a statement error (only `.quit`'s `Stop` is caught, to
/// end cleanly).
internal struct Query: ParsableCommand {
  internal static var configuration: CommandConfiguration {
    CommandConfiguration(commandName: "query",
                         abstract: "Query the database with SQL, or open a "
                                 + "shell.")
  }

  // The database is the required positional and must be declared before the
  // optional `sql`: ArgumentParser binds positionals in declaration order, so
  // with `sql` first, `query db` would bind `db` to `sql` and report the
  // database missing — making the omit-SQL shell form unreachable.
  @OptionGroup
  internal var options: InspectOptions

  @Argument(help: ArgumentHelp("The SQL script to run; omit it to read one "
                             + "from stdin or open an interactive shell."))
  internal var sql: String?

  internal func run() throws {
    // The caller owns the mapping; it must outlive the database, which is a
    // borrowed view over it.
    let data = try Data(contentsOf: options.database.url,
                        options: .alwaysMapped)
    let database = try Database(data.span.bytes)

    // An argument runs as a `;`-separated batch; with none, the shell streams
    // statements from stdin, which `readLine()` reads from a terminal and a
    // pipe alike. Either way the iteration is a literal `for`-in over a
    // `Statements` stream, and each statement runs through `Shell.attempt`,
    // which applies the run's error policy: the batch (`strict`) propagates a
    // statement error to fail fast, while the shell reports it and keeps
    // reading. `.quit`'s `Shell.Stop` is caught either way to end cleanly. The
    // policy lives in `attempt` so `.read` inherits it too.
    let storage = database.storage
    var shell = Shell(storage, strict: sql != nil)
    if let sql {
      do {
        for statement in Statements(of: sql) { try shell.attempt(statement) }
      } catch is Shell.Stop {}
    } else {
      note("winmd-inspect — .help for commands, .quit to leave")
      for statement in Statements(reading: { readLine() }) {
        do {
          try shell.attempt(statement)
        } catch is Shell.Stop {
          break
        }
      }
    }
  }

}

/// Writes `message` and a newline to stderr — the shell's diagnostics (the
/// interactive banner, a statement's `error: …`, a `.read` fault) kept off
/// stdout so a piped run's TSV output stays clean. Shared by the `query` loop
/// and `Shell.read` so every diagnostic lands on the same stream.
internal func note(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
