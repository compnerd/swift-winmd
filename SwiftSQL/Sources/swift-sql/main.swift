// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQLShell

internal import class Foundation.FileHandle
internal import struct Foundation.Data
#if os(Windows)
internal import func ucrt.exit
#elseif os(Linux)
internal import func Glibc.exit
#elseif os(anyAppleOS)
internal import func Darwin.exit
#endif

// The `swift-sql` command — a standalone, `sqlite3`-style SQL REPL over an
// in-memory session. With no arguments it reads statements from stdin (a
// forgiving shell: a fault is reported and the read continues); given file
// paths it runs each as a strict batch (a fault aborts). A read-only engine has
// no persistent storage, so a session works over `VALUES`, common table
// expressions, and the views and functions it defines with `CREATE VIEW` /
// `CREATE FUNCTION`.

/// Writes `text` to standard error with no trailing newline — the prompt and
/// out-of-band notes, kept off stdout so a redirected result stays clean.
private func emit(_ text: String) {
  FileHandle.standardError.write(Data(text.utf8))
}

let paths = Array(CommandLine.arguments.dropFirst())

if paths.isEmpty {
  // Interactive/redirected REPL over stdin — forgiving: a fault is reported and
  // the read continues. The prompt hook emits a primary or continuation prompt
  // before each read (a pending, unterminated statement asks to continue).
  var console = Console(strict: false)
  let statements = Statements(reading: { readLine() },
                              prompt: { pending in
                                emit(pending ? "  ..> " : "sql> ")
                              },
                              multiline: Console.multiline)
  for statement in statements {
    do {
      try console.attempt(statement)
    } catch is Console.Stop {
      break
    } catch {
      // A forgiving `attempt` swallows every fault but `.quit`'s `Stop`, so this
      // is unreachable; report defensively rather than crash.
      emit("error: \(error)\n")
    }
  }
} else {
  // Batch: run each file's statements strictly — the first fault aborts.
  var console = Console(strict: true)
  do {
    for path in paths { try console.read(path) }
  } catch is Console.Stop {
    // A `.quit` ends the batch quietly.
  } catch {
    emit("error: \(error)\n")
    exit(1)
  }
}
