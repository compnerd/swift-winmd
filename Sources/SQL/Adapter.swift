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

// MARK: - View

/// A named `SELECT` registered as a first-class relation.
///
/// A view is a stored query the engine resolves wherever a base table is: its
/// `select` is the query that produces the rows, and `columns` names the
/// relation's columns in projection order — column `i` is the `i`th projected
/// value of `select`. A view is fully escapable data — no borrowed storage — so
/// it sits beside the `~Escapable` base tables in the same catalog namespace; a
/// catalog vends one through `view(named:)`. The engine compiles a view's
/// `select` into a sub-plan and splices it in where the view is named, the
/// outer query addressing the view's columns by their ordinal in `columns`. A
/// view carries no virtual column, so its `extent` is its `columns` count.
public struct View: Hashable, Sendable {
  /// The query the view stands for.
  public let select: Select

  /// The view's column names, in projection order — column `i` is the `i`th
  /// projected value of `select`.
  public let columns: Array<String>

  public init(select: Select, columns: Array<String>) {
    self.select = select
    self.columns = columns
  }
}

// MARK: - Catalog

/// Resolves a relation name to a table or a view.
///
/// The catalog is the engine's only entry into a data source: a `SELECT`'s
/// `FROM` name is looked up here. A name the source does not know as either a
/// table or a view yields `nil` from both, which the engine reports as
/// `SQLError.relation`. The catalog is `~Escapable`, and the `Table` it vends
/// borrows it — a borrowed-storage source may resolve a relation to a view that
/// never escapes the catalog's borrow. A view, by contrast, is escapable data:
/// a catalog that registers none returns `nil` from the default `view(named:)`.
public protocol Catalog: ~Escapable {
  /// The table this catalog vends.
  associatedtype Table: SQL.Table & ~Escapable

  /// The table named `name`, or `nil` if the source has no such base relation.
  @_lifetime(borrow self)
  borrowing func table(named name: String) -> Table?

  /// The view named `name`, or `nil` if the source registers no such view.
  ///
  /// The engine resolves a `FROM`/`JOIN` name against the views first: a name a
  /// catalog registers as a view shadows a base table of the same name. The
  /// default registers no view, so a source without stored queries need not
  /// implement it.
  borrowing func view(named name: String) -> View?
}

extension Catalog where Self: ~Escapable {
  /// A catalog with no stored queries registers no view.
  public borrowing func view(named name: String) -> View? { nil }
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

  /// The real column names, in ordinal order — column `i` of `names` is the
  /// name of the real column at ordinal `i`.
  ///
  /// A relation knows its own column names; the engine reads them to lift a
  /// base table's resolution onto an escapable `Schema` so a join may resolve a
  /// view against a base table uniformly. The virtual columns (`rowid`,
  /// `parent`) are not in `names`; they resolve through `ordinal(of:)`.
  var names: Array<String> { get }

  /// The virtual column names, in ordinal order — virtual `i` of `virtuals`
  /// sits at ordinal `width + i`.
  ///
  /// A virtual column is computed by the `Row` rather than stored (a `rowid`, a
  /// `parent`); naming them lets the engine lift resolution onto an escapable
  /// `Schema`. The default is empty — a relation overrides it only when it
  /// computes a virtual column, and then its `extent` is `width + virtuals.count`.
  var virtuals: Array<String> { get }

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

  /// A relation exposes no virtual column by default.
  public var virtuals: Array<String> { [] }
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
