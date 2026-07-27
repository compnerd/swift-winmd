// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine
public import WinMD

// MARK: - WinMDDatabase

/// A queryable WinMD database — the library's public entry point.
///
/// `WinMDDatabase` opens a borrowed `WinMD.Storage` (the readable projection a
/// caller maps a `.winmd` into) as a `SQLEngine.Catalog`, seeding the bundled
/// COM-interface views and the WinMD-domain routines, so a third-party package
/// can run SQL against a metadata file without touching the engine adapter.
///
/// It is the public face of the internal `Session`: the adapter, its relation,
/// cursor, and row views, and the projection/decode path all stay `package`
/// implementation. The facade forwards every `Catalog` requirement to the
/// wrapped session, so it plugs straight into the engine's
/// `run(_:_:bindings:)`/`columns(of:routines:)` — and any generic that takes a
/// `some Catalog & ~Escapable` — while `run(_ sql:)`/`columns(of sql:)` add the
/// ergonomic string path that parses and auto-supplies `routines`.
///
/// `WinMDDatabase` mirrors the storage's `~Escapable`/`@_lifetime(borrow …)`
/// borrow: it never outlives the `storage` it opens over, and the borrowed
/// relations it vends never outlive it.
public struct WinMDDatabase: SQLEngine.Catalog, ~Escapable {
  /// The wrapped session — the mutable `Catalog` overlaying the bundled and
  /// registered views on the borrowed storage. Held `~Escapable`, its lifetime
  /// tied to the storage the facade opened over.
  private let session: Session

  /// Opens a database over `storage`, seeding the bundled COM-interface views —
  /// or, where a `search` directory shadows or adds one, its view — and the
  /// WinMD-domain routines (`GUID`/`SIGNATURE` and the standard prelude).
  ///
  /// `storage` is the readable projection a caller maps a `.winmd` into (a
  /// `WinMD.Database`'s `storage`); the facade borrows it, so the database must
  /// not outlive the mapped file.
  @_lifetime(borrow storage)
  public init(_ storage: borrowing WinMD.Storage,
              search: Array<String> = []) {
    self.session = Session(storage, search: search)
  }

  /// The routines a query resolves a call against — the WinMD-domain UDFs
  /// (`GUID`/`SIGNATURE`) folded with the standard prelude. Pass these to the
  /// engine's `run`/`columns` overloads, or the generic `Catalog` runners, to
  /// reach the built-ins and the domain decodes; `run(_ sql:)` supplies them
  /// for you.
  public var routines: SQLEngine.Routines {
    session.functions
  }

  // MARK: Catalog

  @_lifetime(borrow self)
  public borrowing func table(named name: String) -> WinMDRelation? {
    session.table(named: name)
  }

  public borrowing func view(named name: String) -> View? {
    session.view(named: name)
  }

  public borrowing func relations() -> Array<String> {
    session.relations()
  }

  public borrowing func views() -> Array<String> {
    session.views()
  }

  // MARK: SQL

  /// Runs one SQL `sql` statement against the database, returning the rows a
  /// `SELECT` (or a `WITH`) yields — the ergonomic string path, parsing the
  /// statement and resolving its calls against `routines` for the caller.
  ///
  /// `bindings` resolve a `:name` parameter of the query. A `CREATE VIEW` or
  /// `CREATE FUNCTION` defines rather than produces rows, so — this being the
  /// read-only query facade — it faults `SQLError.statement`; the bundled views
  /// are already in scope from `init`.
  public borrowing func run(_ sql: String, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    let statement = try Statement(parsing: sql)
    return try session.run(statement, routines, bindings: bindings)
  }

  /// The result columns `sql` would yield, typed with `routines` in scope so a
  /// projected `GUID(...)`/built-in reports its declared type — the schema-only
  /// counterpart of `run(_ sql:)`, deriving the shape without opening a cursor.
  public borrowing func columns(of sql: String)
      throws(SQLError) -> Array<OutputColumn> {
    let statement = try Statement(parsing: sql)
    return try session.columns(of: statement, routines: routines)
  }
}
