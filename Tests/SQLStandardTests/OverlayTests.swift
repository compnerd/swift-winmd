// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine
import SQLStandard
import SQLTestSupport
import Testing

/// A small catalog the overlay tests project the built-ins over.
private func library() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Id": .integer, "Text": .text, "Num": .integer]) {
      Row(1, "aBc", 30)
    }
  }
}

/// The `SQLStandard` overlay: `import SQLStandard` re-defaults the prelude on
/// the pure engine's entry points, and the relocated protected-name and
/// defined-body-capture seams behave exactly as before the split.
@Suite struct OverlayTests {
  @Test func `run defaults the prelude so a built-in resolves without routines`()
      throws {
    // The prelude-defaulting `run(_:bindings:)` overload seeds
    // `Routines.standard`, so UPPER resolves though no routines are passed.
    let rows = try library()
        .run(Statement(parsing: "SELECT UPPER(Text) FROM L WHERE Id = 1"))
    #expect(rows == [[.text("ABC")]])
  }

  @Test func `columns defaults the prelude and types a built-in call`() throws {
    let query = try Statement(parsing: "SELECT UPPER(Text) FROM L")
    guard case let .select(select) = query else {
      throw SQLError.incomplete(expected: "a SELECT")
    }
    let columns = try library().columns(of: select)
    #expect(columns.map(\.type) == [.text])
  }

  @Test func `registering over a protected standard name is rejected`() throws {
    // BITAND is protected in `Routines.standard`; a `registering` of it faults
    // SQLSTATE 42723 through the relocated protected-name seam.
    #expect(throws: SQLError.state("42723",
        "'bitand' is a standard routine and cannot be redefined")) {
      try Routines.standard
          .registering("bitand", parameters: [.integer, .integer]) {
            _ in .null
          }
    }
  }

  @Test func `a defined body binds a prelude built-in via the capture seam`()
      throws {
    // Registered against EMPTY routines, a defined body calling BITAND still
    // resolves it: the two-argument `registering(_:_:)` overload captures
    // `Routines.standard` (the relocated early-binding capture).
    guard case let .function(name, function) =
        try Statement(parsing: "CREATE FUNCTION lowbit(n INTEGER) "
                          + "RETURNS INTEGER AS BITAND(n, 1)")
    else { throw SQLError.incomplete(expected: "a CREATE FUNCTION") }
    let routines = try Routines().registering(name, function)
    let rows = try library()
        .run(Statement(parsing: "SELECT lowbit(Num) FROM L WHERE Id = 1"),
             routines)
    // Num is 30 (even); BITAND(30, 1) = 0.
    #expect(rows == [[.integer(0)]])
  }

  @Test func `the standard prelude declares BITAND over two integers`() {
    #expect(Routines.standard["bitand"]?.returns == .integer)
    #expect(Routines.standard["bitand"]?.parameters == [.integer, .integer])
  }
}
