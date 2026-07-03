// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The common table expressions in scope, keyed case-folded — the materialised
/// relations the engine resolves a `WITH`'s names against.
///
/// It is threaded alongside the borrowed base catalog through every resolution
/// phase: when the engine resolves a relation name, it consults `CTEs` first (a
/// CTE name shadows a base table or view of the same name), and a CTE leaf
/// materialises its records from the `Materialised` rows rather than opening a
/// base cursor. An empty `CTEs` is the default — a query with no `WITH` resolves
/// exactly as before. Threading escapable data sidesteps wrapping the borrowed
/// `~Escapable` base catalog in a unifying overlay type.
internal typealias CTEs = Dictionary<String, Materialised>

/// An escapable, in-engine relation over `(columns, rows)`.
///
/// A `Materialised` is fully owned data — a common table expression's query run
/// to a fixed set of rows, named by its columns — that the engine resolves a
/// CTE name to. It is escapable, so it sits beside the `~Escapable` base
/// catalog without the lifetime machinery a borrowed source needs: the engine
/// threads a `Dictionary<String, Materialised>` of the in-scope CTEs alongside
/// the borrowed base catalog, consulting it first when it resolves a name, and
/// builds the leaf records directly from `rows` rather than opening a cursor.
///
/// It exposes the universal `Id` virtual column at `width`, so a CTE
/// resolves columns exactly as a base relation does (a real column below
/// `width`, the `Id` at `width`).
internal struct Materialised: Hashable, Sendable {
  /// The relation's column names, in ordinal order.
  internal let columns: Array<String>

  /// The relation's rows, each a positional array of typed values.
  internal let rows: Array<Array<Value>>

  internal init(columns: Array<String>, rows: Array<Array<Value>>) {
    self.columns = columns
    self.rows = rows
  }

  /// The real column count — the extent of a `SELECT *`.
  internal var width: Int { columns.count }

  /// One past the highest ordinal — the real width plus the lone virtual
  /// `Id` column at `width`.
  internal var extent: Int { width + 1 }

  /// The resolution schema of this relation: its columns below `width`, a
  /// virtual `Id` at `width`.
  internal func schema() -> Schema {
    Schema(width: width, extent: extent, names: columns,
           types: Array(repeating: .integer, count: width), virtuals: ["Id"])
  }

  /// The record for the row at `index`, materialising the referenced `ordinals`
  /// into dense slots — a real ordinal (`< width`) reads the stored cell, the
  /// virtual `Id` ordinal (`== width`) the 1-based row index.
  internal func record(_ index: Int, _ ordinals: Array<Int>) -> Record {
    let cells = rows[index]
    return Record(ordinals.map {
      $0 == width ? .integer(index + 1) : cells[$0]
    })
  }
}
