// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

internal import ArgumentParser

@testable import winmd_inspect

struct QueryTests {
  @Test("the database is the first positional; SQL is optional and follows it")
  func optionalSQLFollowsDatabase() throws {
    // `query <db>` with no SQL must bind `db` to the database and leave `sql`
    // nil — the stdin/shell form. Were `sql` declared first, ArgumentParser
    // would bind `db` to `sql` and report the database missing, so this parse
    // would throw. The database is parsed as a path; no file need exist.
    let shell = try Query.parse(["fixture.winmd"])
    #expect(shell.sql == nil)
    #expect(shell.options.database.url.lastPathComponent == "fixture.winmd")

    // With a SQL argument, the database still binds first and `sql` takes the
    // second positional.
    let scripted = try Query.parse(["fixture.winmd", "SELECT 1"])
    #expect(scripted.sql == "SELECT 1")
    #expect(scripted.options.database.url.lastPathComponent == "fixture.winmd")
  }
}
