// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQL

/// Fluent builders over the fixture store, so a test writes a catalog the way
/// it reads — a nesting of relations, rows, and views — rather than assembling
/// `FixtureField`/`FixtureRelation`/`FixtureCatalog` values by hand.
///
/// A `Catalog { … }` gathers `Relation`/`View` members; a `Relation` gathers
/// `Row` members; a `Row` takes bare Swift literals a `ValueConvertible` lifts
/// into `Value`s, so `Row(1, "Alice", 30)` needs no `.integer(…)`/`.text(…)`
/// ceremony. The schema is an ordered `KeyValuePairs<String, ValueType>` so a
/// column's position is its declaration order, and `sorted:` marks a column
/// seekable — driving the fixture store's binary-search `bound`.

// MARK: - ValueConvertible

/// A Swift value that lifts into a SQL `Value`, so a fixture row is written
/// with bare literals rather than `.integer(…)`/`.text(…)` cases.
public protocol ValueConvertible {
  /// The `Value` this lifts to.
  var value: Value { get }
}

extension Value: ValueConvertible {
  public var value: Value { self }
}

extension Int: ValueConvertible {
  public var value: Value { .integer(self) }
}

extension String: ValueConvertible {
  public var value: Value { .text(self) }
}

extension Bool: ValueConvertible {
  public var value: Value { .boolean(self) }
}

extension Double: ValueConvertible {
  public var value: Value { .double(self) }
}

extension Array: ValueConvertible where Element == UInt8 {
  public var value: Value { .blob(self) }
}

/// A `nil` literal projects SQL `NULL`. An `Optional<some ValueConvertible>`
/// carries a value when present and `NULL` when absent, so `Row(1, nil)` and a
/// computed optional cell both read as their SQL counterparts.
extension Optional: ValueConvertible where Wrapped: ValueConvertible {
  public var value: Value {
    switch self {
    case let .some(wrapped): wrapped.value
    case .none: .null
    }
  }
}

// MARK: - Row builder

/// A builder-gathered row of fixture cells, each a Swift literal the enclosing
/// `Relation` stores as a `Value`.
public struct Row {
  /// The row's cells, in column order.
  public let cells: Array<Value>

  /// A row of the given cells, each lifted from its Swift literal. A cell is an
  /// optional `any ValueConvertible` so a bare `nil` literal — which carries no
  /// type of its own — projects SQL `NULL`, beside the concrete literals.
  public init(_ cells: (any ValueConvertible)?...) {
    self.cells = cells.map { $0?.value ?? .null }
  }
}

/// Gathers the `Row`s of a `Relation` body into an array of value rows.
@resultBuilder
public enum RowBuilder {
  public static func buildExpression(_ row: Row) -> Array<Value> {
    row.cells
  }

  public static func buildBlock(_ rows: Array<Value>...)
      -> Array<Array<Value>> {
    rows
  }

  public static func buildArray(_ rows: Array<Array<Array<Value>>>)
      -> Array<Array<Value>> {
    rows.flatMap { $0 }
  }
}

// MARK: - Catalog members

/// A catalog member — a base `Relation` or a stored `View` — the
/// `CatalogBuilder` gathers and `Catalog { … }` assembles into a
/// `FixtureCatalog`.
public enum Member {
  case relation(name: String, FixtureRelation)
  case view(name: String, SQL.View)
}

/// A named base relation: an ordered schema, its rows, and an optional seekable
/// column.
///
/// The schema is a `KeyValuePairs<String, ValueType>` so a column's ordinal is
/// its declaration order; `sorted:` names the column whose rows are stored in
/// ascending order, which the fixture store's `bound` seeks (and any other
/// column scans). The body lists the rows as `Row(…)` literals.
public struct Relation {
  public let member: Member

  public init(_ name: String,
              _ schema: KeyValuePairs<String, ValueType>,
              sorted column: String? = nil,
              @RowBuilder rows: () -> Array<Array<Value>> = { [] }) {
    let fields = schema.map { FixtureField(name: $0.key, type: $0.value) }
    // Fold the sorted-column name like the engine folds identifiers, so
    // `sorted: "id"` matches a declared `Id`; a name matching no column is a
    // fixture error and traps rather than silently building an unsorted
    // relation that would skip the seek path a test means to exercise.
    let sorted = column.map { name in
      guard let index = fields.firstIndex(where: {
        $0.name.lowercased() == name.lowercased()
      }) else {
        preconditionFailure("Relation has no column '\(name)' to sort on")
      }
      return index
    }
    member =
        .relation(name: name,
                  FixtureRelation(fields, rows(), sorted: sorted))
  }
}

/// A named view: a `SELECT` parsed from its SQL text plus the column names its
/// rows expose in projection order.
///
/// The SQL is parsed through the engine's public `Statement(parsing:)` entry,
/// so a view built here means exactly what the engine resolves it to; a
/// non-`SELECT` statement traps as a fixture-construction error.
public struct View {
  public let member: Member

  public init(_ name: String, _ sql: String, as columns: Array<String>) throws {
    let query = try Self.query(sql)
    member = .view(name: name, SQL.View(query: query, columns: columns))
  }

  /// Parses `sql` to a `Query`, trapping on any other statement — a fixture's
  /// view text is a literal the test author controls, so a non-`SELECT` is a
  /// construction bug rather than a run-time condition to recover from.
  private static func query(_ sql: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: sql) else {
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }
}

/// Gathers the `Relation`/`View` members of a `Catalog` body.
@resultBuilder
public enum CatalogBuilder {
  public static func buildExpression(_ relation: Relation) -> Member {
    relation.member
  }

  public static func buildExpression(_ view: View) -> Member {
    view.member
  }

  public static func buildBlock(_ members: Member...) -> Array<Member> {
    members
  }

  public static func buildArray(_ members: Array<Array<Member>>)
      -> Array<Member> {
    members.flatMap { $0 }
  }
}

// MARK: - Catalog

/// Builds a `FixtureCatalog` from a fluent body of `Relation`/`View` members.
///
/// A `try Catalog { Relation(…); View(…) }` reads as the schema it defines,
/// registering each base relation and each stored view by name — the shared
/// framework's front door for a test's data source. `try` because a `View`
/// parses its SQL, which may fault; a `View` naming a column no relation
/// defines still resolves lazily at query time as a hand-built one does.
public func Catalog(@CatalogBuilder _ members: () throws -> Array<Member>)
    throws -> FixtureCatalog {
  var relations = Dictionary<String, FixtureRelation>()
  var views = Dictionary<String, SQL.View>()
  for member in try members() {
    switch member {
    case let .relation(name, relation):
      relations[name] = relation
    case let .view(name, view):
      views[name] = view
    }
  }
  return FixtureCatalog(relations, views: views)
}
