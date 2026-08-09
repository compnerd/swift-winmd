// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The execution convenience — handing a built query straight to a catalog. The
// module is prelude-agnostic (it depends only on `SQLEngine`, not
// `SQLStandard`), so these take the `Routines` explicitly, exactly as the pure
// engine `Catalog.run(_:_:bindings:)` does; a caller under `import SQL` passes
// `Routines.standard` (or uses the engine overloads directly). The catalog is a
// borrowing `~Escapable` parameter, so a query builder cannot capture it — the
// builder is handed to the catalog rather than the reverse.

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
  /// row (`FETCH FIRST 1 ROW ONLY`) rather than the whole result — but never
  /// more than a stricter cap already set, so `limit(0).first` still yields nil
  /// (`capped(at:)` takes the minimum, not `limit(1)` which would expand it).
  public borrowing func first<C>(against catalog: borrowing C,
                                 routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Value>? where C: Catalog & ~Escapable {
    try capped(at: 1).run(against: catalog, routines: routines,
                          bindings: bindings).first
  }

  /// The sole result row: `nil` if the query yields none, the row if exactly
  /// one, `SQLError.cardinality` if more — LINQ `Single`/`SingleOrDefault`.
  /// Fetches up to two rows to detect a surplus, capped at any stricter
  /// existing `limit` (after `limit(1)` it fetches one and never over-reports
  /// cardinality).
  public borrowing func single<C>(against catalog: borrowing C,
                                  routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Value>? where C: Catalog & ~Escapable {
    let rows = try capped(at: 2).run(against: catalog, routines: routines,
                                     bindings: bindings)
    guard rows.count <= 1 else { throw .cardinality }
    return rows.first
  }

  /// Whether the query yields any row — LINQ `Any` (no predicate; the predicate
  /// form is `.where(p).any(against:)`). Fetches one row rather than counting,
  /// capped at any stricter existing `limit` so `limit(0).any` is `false`.
  /// Distinct from the free `any(_ subquery:)` quantifier used in a comparison
  /// — this is a terminal on the builder.
  public borrowing func any<C>(against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Bool where C: Catalog & ~Escapable {
    try !capped(at: 1).run(against: catalog, routines: routines,
                           bindings: bindings).isEmpty
  }

  /// The number of rows the query yields — LINQ `Count`. It runs the query and
  /// counts the result rows, so it reflects the whole shape the chain builds
  /// (a `distinct`, a `group(by:)`, a `limit`/`offset`), exactly as `first`/
  /// `any` execute and reduce rather than build a fresh statement.
  public borrowing func count<C>(against catalog: borrowing C,
                                 routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Int where C: Catalog & ~Escapable {
    try run(against: catalog, routines: routines, bindings: bindings).count
  }

  /// Whether every row of the sequence satisfies `predicate` — LINQ `All`, the
  /// SQL `NOT EXISTS (… WHERE NOT predicate)`: TRUE when no row falsifies it,
  /// so an empty sequence is vacuously TRUE and a row whose predicate is
  /// UNKNOWN (a NULL) is not a violation. It tests for a falsifying row, and
  /// where that test applies turns on whether the query is `shaped`. A shaped
  /// query — a GROUP BY/HAVING folds its rows or a LIMIT/OFFSET pages them — is
  /// wrapped as a derived table so the negation applies to the shaped output
  /// (`.limit(1).all(p)` judges the one row the page yields, not one a
  /// pre-filter exposes), and `predicate` names the projected columns. An
  /// unshaped select/join keeps its own scope: the negation is conjoined into
  /// its `WHERE`, so the query's own relations and aliases resolve
  /// (`all(column("e.Salary") > 0)` over `from("Employees", as: "e")`).
  public borrowing func all<C>(_ predicate: Filter,
                               against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Bool where C: Catalog & ~Escapable {
    if shaped {
      return try !nested(as: "source").filtering(by: !predicate)
          .any(against: catalog, routines: routines, bindings: bindings)
    }
    return try !filtering(by: !predicate)
        .any(against: catalog, routines: routines, bindings: bindings)
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

extension Defaulted {
  /// Runs this `DefaultIfEmpty` against `catalog` through `routines` and
  /// `bindings`, returning its result rows — the source's rows, or the one
  /// default row when the source is empty. It hands the `WITH` statement to the
  /// engine `Catalog.run(_:_:bindings:)` so the source materializes once.
  public borrowing func run<C>(against catalog: borrowing C,
                               routines: Routines, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> where C: Catalog & ~Escapable {
    try catalog.run(statement, routines, bindings: bindings)
  }

  /// The result columns this `DefaultIfEmpty` would yield against `catalog`.
  public borrowing func columns<C>(against catalog: borrowing C,
                                   routines: Routines, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> where C: Catalog & ~Escapable {
    try catalog.columns(of: statement, routines: routines, validate: validate)
  }
}
