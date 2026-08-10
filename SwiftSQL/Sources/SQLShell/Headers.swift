// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The box-table header derivation a shell falls back to when the resolved
// result schema cannot type a statement — the query's SYNTACTIC projection.
// A shell prefers the resolved schema (real names for a plain/base/empty query
// and a WITH's CTE-scoped trailing query); only when that derive cannot resolve
// does it read the trailing query's syntactic projection here.

public enum Headers {
  /// The syntactic column headers of `statement`'s row-producing query, sized
  /// to `rows` — the fallback when the resolved-schema derive cannot type it (a
  /// `WITH`'s trailing query over a CTE). `nil` for a definition (`CREATE
  /// VIEW`/`CREATE FUNCTION`), which names no result columns, so the caller
  /// prints nothing.
  public static func syntactic(of statement: Statement,
                               _ rows: Array<Array<Value>>) -> Array<String>? {
    switch statement {
    case .create, .function:
      return nil
    case let .select(query), let .explain(query):
      return names(of: query, rows)
    case let .with(_, query):
      return names(of: query, rows)
    }
  }

  /// `column N` headers for `rows`' produced width — the fallback when a column
  /// name cannot be recovered (a `SELECT *` over a join, an unresolved
  /// relation, or an unparsable statement), so a non-empty result still frames.
  public static func generic(_ rows: Array<Array<Value>>) -> Array<String> {
    (0 ..< (rows.first?.count ?? 0)).map { "column \($0 + 1)" }
  }

  /// The syntactic headers of a `query` — the names off its leftmost arm's
  /// projection (the ISO rule a set operation's result columns follow); a body
  /// with no syntactic projection frames by the produced width.
  private static func names(of query: SQLEngine.Query,
                            _ rows: Array<Array<Value>>) -> Array<String> {
    switch query.arm.body {
    case let .select(select):
      return names(of: select.projection, rows)
    case let .values(tuples):
      // The ISO table value constructor's default output names.
      return (0 ..< (tuples.first?.count ?? 0)).map { "column\($0 + 1)" }
    case .setop:
      return generic(rows)
    }
  }

  private static func names(of projection: SQLEngine.Projection,
                            _ rows: Array<Array<Value>>) -> Array<String> {
    switch projection {
    case let .columns(list):
      list.map(\.name)
    case let .expressions(items):
      items.enumerated().map { index, item in
        item.alias ?? column(item.expression) ?? "column \(index + 1)"
      }
    case .all:
      generic(rows)
    }
  }

  /// The output name of a projected `expression` — a bare column's name (the
  /// qualifier dropped), or `nil` for a computed expression that names no
  /// column, which the derivation falls back to a positional label.
  private static func column(_ expression: Expression) -> String? {
    if case let .column(column) = expression { column.name } else { nil }
  }
}
