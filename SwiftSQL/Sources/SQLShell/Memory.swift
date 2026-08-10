// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// An in-memory catalog for a standalone shell: no base tables (a read-only
// engine has no CREATE TABLE), only the views a session registers. A query
// works over VALUES, CTEs, and those registered views.

/// A `Catalog` holding only registered views and no base relations.
///
/// A `MemoryCatalog` is an escapable value (owned data), so it conforms to the
/// `~Escapable` catalog protocols by omitting the `@_lifetime` a borrowed-
/// storage source would annotate — exactly as the fixture catalog does. Its
/// `views` are keyed case-folded, the way the engine resolves a relation name.
public struct MemoryCatalog: Catalog {
  /// The registered views, keyed case-folded.
  private let registered: Dictionary<String, View>

  /// Registers `views`, case-folding each supplied key so a naturally-cased
  /// name (`"MyView"`) resolves through the case-insensitive `view(named:)`,
  /// the way `Database` and the engine key a relation. Two keys that fold to
  /// the same name keep the last.
  public init(views: Dictionary<String, View> = [:]) {
    registered = Dictionary(views.map { ($0.key.lowercased(), $0.value) },
                            uniquingKeysWith: { $1 })
  }

  public func table(named name: String) -> MemoryTable? { nil }

  public func view(named name: String) -> View? {
    registered[name.lowercased()]
  }

  public func relations() -> Array<String> { [] }

  public func views() -> Array<String> { Array(registered.keys) }
}

/// The `Table` a `MemoryCatalog` names — never actually vended, since the
/// catalog holds no base relation. It exists only to satisfy `Catalog.Table`,
/// so its schema is empty and its cursor walks no row.
public struct MemoryTable: Table {
  public var width: Int { 0 }
  public var names: Array<String> { [] }
  public func ordinal(of name: String) -> Int? { nil }
  public func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? { nil }
  public func cursor() -> MemoryCursor { MemoryCursor() }
}

/// The empty cursor a `MemoryTable` vends — no rows.
public struct MemoryCursor: Cursor {
  public var count: Int { 0 }
  public func row(_ index: Int) -> MemoryRow? { nil }
}

/// The row a `MemoryCursor` would vend — never reached (the cursor is empty).
public struct MemoryRow: Row {
  public subscript(_ column: Int) -> Value { .null }
}
