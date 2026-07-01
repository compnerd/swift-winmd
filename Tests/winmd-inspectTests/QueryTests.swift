// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

import ArgumentParser

import class Foundation.FileManager
import struct Foundation.Data
import struct Foundation.UUID

@testable import winmd_inspect

struct QueryTests {
  /// Runs `body` with the path of a fresh, empty regular file that exists for
  /// the call and is removed after. The root's `validate` (run on every parse)
  /// requires the database to be an existing regular file, so a parse test
  /// binds a real path rather than a made-up one.
  private static func withDatabase(_ body: (String) throws -> Void) rethrows {
    // A fresh per-call directory keeps the filename `fixture.winmd` (the parses
    // assert its `lastPathComponent`) while a `UUID` isolates concurrently
    // running tests — swift-testing runs them in parallel, so a shared path
    // would race a peer's cleanup.
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

  @Test("the database leads the command line; SQL is an optional positional")
  func databaseLeadsSQL() throws {
    try QueryTests.withDatabase { database in
      // The database leads the command line as the root's positional — the
      // subcommand comes after it — and is propagated into the subcommand's
      // `InspectOptions`. `<db> query` with no script opens the shell, so `sql`
      // is nil.
      let shell = try #require(try Inspect.parseAsRoot([database, "query"])
                                   as? Query)
      #expect(shell.sql == nil)
      #expect(shell.options.database.url.lastPathComponent == "fixture.winmd")

      // `<db> query '<sql>'` runs the script: the trailing positional binds to
      // `sql` (declared before the database group), the database still leading.
      // Were the group declared first, the propagated database would swallow the
      // script and ArgumentParser would report it "unexpected".
      let scripted =
          try #require(try Inspect.parseAsRoot([database, "query", "SELECT 1"])
                           as? Query)
      #expect(scripted.sql == "SELECT 1")
      #expect(scripted.options.database.url.lastPathComponent
                  == "fixture.winmd")

      // A `dump` reads the same leading database — one positional, before the
      // verb, for every subcommand.
      let dumped = try #require(try Inspect.parseAsRoot([database, "dump"])
                                    as? Dump)
      #expect(dumped.options.database.url.lastPathComponent == "fixture.winmd")
    }
  }

  @Test("the leading database is validated to be an existing file")
  func validatesDatabase() throws {
    // The root validates the leading `<database>` before dispatching, so a
    // non-existent path fails the parse whichever subcommand follows.
    #expect(throws: (any Error).self) {
      _ = try Inspect.parseAsRoot(["does-not-exist.winmd", "query"])
    }
    #expect(throws: (any Error).self) {
      _ = try Inspect.parseAsRoot(["does-not-exist.winmd", "dump"])
    }
  }
}
