// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine
internal import SQLStandard

// The standalone shell's mutable catalog state — an in-memory session with no
// base tables, growing the views and functions a REPL defines across
// statements. It is the escapable counterpart of the winmd `Session`: a query
// works over VALUES, CTEs, and the views/functions the session has registered.

/// An in-memory SQL session: a `Catalog` that registers `CREATE VIEW` /
/// `CREATE FUNCTION` and runs `SELECT`/`WITH`/`EXPLAIN` against them.
///
/// `Database` holds the views (case-folded) and the routines a session defines,
/// seeded with the standard prelude so a built-in (`UPPER`, `SUBSTRING`, …)
/// resolves without registration. It is an escapable value — no borrowed
/// storage — so, unlike the winmd `Session`, it is not `~Escapable`. A read-only
/// engine has no `CREATE TABLE`, so the base relations stay empty; a session
/// works over `VALUES`, common table expressions, and the views it registers.
public struct Database: Catalog {
  /// The views a `CREATE VIEW` has registered, keyed case-folded — the way the
  /// engine resolves a relation name.
  private var registered: Dictionary<String, View>

  /// The routines in scope — the standard prelude a `CREATE FUNCTION` grows.
  public private(set) var functions: Routines

  public init() {
    registered = [:]
    functions = .standard
  }

  public func table(named name: String) -> MemoryTable? { nil }

  public func view(named name: String) -> View? {
    registered[name.lowercased()]
  }

  public func relations() -> Array<String> { [] }

  public func views() -> Array<String> { Array(registered.keys) }

  /// Runs one SQL `statement`, returning the rows a `SELECT`/`WITH`/`EXPLAIN`
  /// yields — or none for a `CREATE VIEW`, which registers its `View`, or a
  /// `CREATE FUNCTION`, which registers its scalar `Function` into the session's
  /// routines (each key case-folded). `bindings` resolve a `:name` parameter of
  /// a row-producing statement. It mirrors the winmd `Session.run`, over an
  /// in-memory base rather than a `.winmd`.
  public mutating func run(_ statement: String, bindings: Bindings = [:])
      throws -> Array<Array<Value>> {
    let parsed = try Statement(parsing: statement)
    switch parsed {
    case let .create(name, view):
      registered[name.lowercased()] = view
      return []
    case let .function(name, function):
      functions = try functions.registering(name, function)
      return []
    case .select, .explain, .with:
      return try run(parsed, functions, bindings: bindings)
    }
  }

  /// The result columns `statement` would yield, typed with the session's
  /// routines in scope — the schema-only counterpart of `run`, for `.schema`
  /// and the box headers.
  public func columns(of statement: Statement, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    try columns(of: statement, routines: functions, validate: validate)
  }
}
