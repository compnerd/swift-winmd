// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The engine's adapter surface — the protocols a data source conforms to so
/// the planner and executor run over it without knowing what it is.
///
/// The engine plans and executes a `SELECT` entirely against these four
/// protocols. A `Catalog` resolves a relation name to a `Table`; a `Table`
/// describes the relation's schema (its real width and a name → ordinal map,
/// real or virtual) and vends a `Cursor` over its rows; a `Cursor` addresses
/// rows by index; a `Row` reads a typed cell by ordinal. Every protocol is
/// `~Escapable`, so a source backed by borrowed storage — a `Span` over a
/// mapped file — conforms to the same surface as an escapable, owned source: a
/// `Catalog`/`Table` hands back a borrowed `Table`/`Cursor` that never outlives
/// the borrow, and a `Cursor` vends a `Row` view tied to its own lifetime. The
/// engine yields typed `Value`s, never rendered text; turning a value into a
/// display string is a client's job.

// MARK: - Values

/// The kind of value a column holds.
///
/// A column is either integral or textual. A source uses this to describe its
/// schema and to build the typed `Value`s a `Row` yields; the engine itself
/// compares and orders on the `Value`, not the kind.
public enum ValueKind: Hashable, Sendable {
  /// An integral column.
  case integer
  /// A textual column.
  case text
}

/// A typed cell value the engine yields.
///
/// The engine projects each surviving row to an `Array<Value>` — the result is
/// data, not rendered text — so a client may format, compare, or re-key it.
public enum Value: Hashable, Sendable {
  /// An integral value.
  case integer(Int)
  /// A textual value.
  case text(String)
}

// MARK: - Catalog

/// Resolves a relation name to a table.
///
/// The catalog is the engine's only entry into a data source: a `SELECT`'s
/// `FROM` name is looked up here. A name the source does not know yields `nil`,
/// which the engine reports as `SQLError.relation`. The catalog is `~Escapable`,
/// and the `Table` it vends borrows it — a borrowed-storage source may resolve a
/// relation to a view that never escapes the catalog's borrow.
public protocol Catalog: ~Escapable {
  /// The table this catalog vends.
  associatedtype Table: SQL.Table & ~Escapable

  /// The table named `name`, or `nil` if the source has no such relation.
  @_lifetime(borrow self)
  borrowing func table(named name: String) -> Table?
}

// MARK: - Table

/// A relation's schema and its cursor factory.
///
/// A `Table` knows its real column count (`width`, the extent of `SELECT *`),
/// its `extent` (one past the highest ordinal it can address, real or virtual),
/// resolves a column name to an ordinal (a real ordinal `< width`, or a virtual
/// ordinal `>= width` for a computed column such as a `rowid`), and — for a
/// column whose rows are stored in sorted order — maps a comparison value to a
/// row boundary so the executor can seek rather than scan. `cursor()` borrows
/// the table and hands back a cursor tied to that borrow.
public protocol Table: ~Escapable {
  /// The cursor this table vends over its rows.
  associatedtype Cursor: SQL.Cursor & ~Escapable

  /// The number of real columns — the extent of a `SELECT *` projection.
  var width: Int { get }

  /// One past the highest ordinal this table can address — its real `width`
  /// plus the virtual columns it exposes.
  ///
  /// A relation with no virtual column has `extent == width`; one exposing a
  /// `rowid` at `width` has `extent == width + 1`, and so on. A join lays the
  /// inner relation immediately past the outer's `extent` so an outer virtual
  /// column never collides with the inner's space. The default is `width` — a
  /// relation overrides it only when it computes a virtual column.
  var extent: Int { get }

  /// The ordinal of the column named `name`, or `nil` if the relation has no
  /// such column.
  ///
  /// A real column resolves to an ordinal `< width`; a virtual column — one the
  /// `Row` computes rather than stores, such as a `rowid` — resolves to an
  /// ordinal `>= width`.
  func ordinal(of name: String) -> Int?

  /// The boundary row for a sorted-seek over `column` against `value`, or `nil`
  /// if the column is not seekable (the engine then scans).
  ///
  /// When the rows are sorted on `column`, this returns the partition point for
  /// `value`: with `strict` false, the first row whose cell is `>= value`; with
  /// `strict` true, the first row whose cell is `> value`. A column that is not
  /// stored sorted returns `nil`, and the executor falls back to a scan.
  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int?

  /// A cursor over the table's rows.
  @_lifetime(borrow self)
  borrowing func cursor() -> Cursor
}

extension Table where Self: ~Escapable {
  /// A relation with no virtual column ends at its real `width`.
  public var extent: Int { width }
}

// MARK: - Cursor

/// An index-addressed view over a relation's rows.
///
/// A `~Escapable` view cannot conform to `Sequence`/`IteratorProtocol`, so the
/// executor walks it by index — `0 ..< count`, reading `row(i)`. A row borrows
/// the cursor and never escapes that borrow.
public protocol Cursor: ~Escapable {
  /// The row this cursor vends.
  associatedtype Row: SQL.Row & ~Escapable

  /// The number of rows the cursor walks.
  var count: Int { get }

  /// The row at `index`, or `nil` if `index` is out of range.
  @_lifetime(copy self)
  borrowing func row(_ index: Int) -> Row?
}

// MARK: - Row

/// A positional view over the cells of a single row.
///
/// A cell is read by ordinal as a typed `Value` — the source decides whether the
/// ordinal names an integral or a textual cell, and a virtual ordinal (one
/// `>= Table.width`) is computed here rather than stored. The row borrows its
/// cursor and never escapes that borrow; the `Value` it yields is owned and
/// escapable.
public protocol Row: ~Escapable {
  /// The typed cell of column `column`.
  subscript(_ column: Int) -> Value { borrowing get }
}
