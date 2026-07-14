// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The execution convenience — handing a built query straight to a catalog. The
// module is prelude-agnostic (it depends only on `SQLEngine`, not
// `SQLStandard`), so these take the `Routines` explicitly, exactly as the pure
// engine `Catalog.run(_:_:bindings:)` does; a caller under `import SQL` passes
// `Routines.standard` (or uses the engine overloads directly). The catalog is a
// borrowing `~Escapable` parameter, so a query builder cannot capture it — the
// builder is handed TO the catalog rather than the reverse.

extension QueryBuilder {
  /// Runs this query against `catalog` through `routines` and `bindings`,
  /// returning its result rows. It lowers to `Query` and hands it to the pure
  /// engine `Catalog.run(_:_:bindings:)`.
  public borrowing func run<C>(against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> where C: Catalog & ~Escapable {
    try catalog.run(query, routines, bindings: bindings)
  }

  /// The result columns this query would yield against `catalog`, typed through
  /// `routines` — the schema-only counterpart of `run(against:…)`, resolving
  /// the query without opening a cursor.
  public borrowing func columns<C>(against catalog: borrowing C,
                                   routines: Routines, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> where C: Catalog & ~Escapable {
    try catalog.columns(of: query, routines: routines, validate: validate)
  }

  /// The first result row, or `nil` if the query yields none — LINQ
  /// `First`/`FirstOrDefault` (Swift spells both as an Optional). Fetches one
  /// row (`FETCH FIRST 1 ROW ONLY`) rather than the whole result.
  public borrowing func first<C>(against catalog: borrowing C,
                                 routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Value>? where C: Catalog & ~Escapable {
    try limit(1).run(against: catalog, routines: routines,
                     bindings: bindings).first
  }

  /// The sole result row: `nil` if the query yields none, the row if exactly
  /// one, `SQLError.cardinality` if more — LINQ `Single`/`SingleOrDefault`.
  /// Fetches up to two rows to detect a surplus.
  public borrowing func single<C>(against catalog: borrowing C,
                                  routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Value>? where C: Catalog & ~Escapable {
    let rows = try limit(2).run(against: catalog, routines: routines,
                                bindings: bindings)
    guard rows.count <= 1 else { throw .cardinality }
    return rows.first
  }

  /// Whether the query yields any row — LINQ `Any` (no predicate; the predicate
  /// form is `.where(p).any(against:)`). Fetches one row rather than counting.
  /// Distinct from the free `any(_ subquery:)` quantifier used in a comparison
  /// — this is a terminal on the builder.
  public borrowing func any<C>(against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Bool where C: Catalog & ~Escapable {
    try !limit(1).run(against: catalog, routines: routines,
                      bindings: bindings).isEmpty
  }
}

extension SetQuery {
  /// Runs this set operation against `catalog` through `routines` and
  /// `bindings`, returning its result rows.
  public borrowing func run<C>(against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> where C: Catalog & ~Escapable {
    try catalog.run(query, routines, bindings: bindings)
  }

  /// The result columns this set operation would yield against `catalog`.
  public borrowing func columns<C>(against catalog: borrowing C,
                                   routines: Routines, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> where C: Catalog & ~Escapable {
    try catalog.columns(of: query, routines: routines, validate: validate)
  }
}
