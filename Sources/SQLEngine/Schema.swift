// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A relation's name-resolution surface, lifted off the live data source.
///
/// Compilation resolves a column name to an ordinal, classifies a projection,
/// and lowers a predicate using only a relation's `width`, its `extent`, and
/// its name → ordinal map — never its `bound` seekability or its `cursor`,
/// which the optimiser and executor re-read from the live source by name. A
/// `Schema` is that escapable resolution surface, pure data: a base `Table`
/// projects to one (its real `names` below `width`, its `virtuals` at and past
/// it), and a compiled `View` projects to one too (its `columns` in projection
/// order, no virtual column). Lifting resolution onto a `Schema` lets a join
/// resolve a base table against a view uniformly — the two live sources need
/// not share a type, only a schema.
internal struct Schema {
  /// The real columns — the extent of a `SELECT *` projection.
  internal let width: Int

  /// One past the highest ordinal the relation can address — its real `width`
  /// plus any virtual columns. A view exposes none, so its `extent` is `width`.
  internal let extent: Int

  /// The real column names at their ordinals `0 ..< width`.
  internal let names: Array<String>

  /// The value type of each real column at its ordinal `0 ..< width` — type `i`
  /// types the column named `names[i]`, so `types.count == width`. It describes
  /// the schema (the `INFORMATION_SCHEMA` overlay's `data_type`,
  /// `Engine.outputSchema`); the engine never compares or orders on it.
  internal let types: Array<ValueType>

  /// The virtual column names at their ordinals `width ..< extent` — virtual
  /// `i` sits at ordinal `width + i`. A view supplies none.
  internal let virtuals: Array<String>

  internal init(width: Int, extent: Int, names: Array<String>,
                types: Array<ValueType>, virtuals: Array<String>) {
    self.width = width
    self.extent = extent
    self.names = names
    self.types = types
    self.virtuals = virtuals
  }

  /// A view's resolution schema, its per-column types RESOLVED from a body
  /// `carrier` while its `names` stay the view's DECLARED ones (a view stores
  /// its own column names; only the types come from the resolved body). The
  /// declared surface's `extent`/`virtuals` carry over unchanged. Taking the
  /// types from the carrier as a whole means a future per-column attribute on
  /// `ResolvedColumn` threads through this ONE constructor rather than a loose
  /// `types.map` at the site.
  internal init(from carrier: Array<ResolvedColumn>, names: Array<String>,
                extent: Int, virtuals: Array<String>) {
    self.init(width: names.count, extent: extent, names: names,
              types: carrier.map(\.type), virtuals: virtuals)
  }

  /// This schema with its real column `names` positionally RENAMED to
  /// `columns` — the ISO `AS t(c, …)` explicit output column list — or
  /// unchanged when `columns` is empty (no list).
  ///
  /// The list renames exactly the REAL columns (the `width` a `SELECT *`
  /// exposes), leaving `virtuals` (the engine's `Id`) addressable by their own
  /// names, so `T AS t(c, d)` renames `T`'s columns while `t.Id` still
  /// resolves. `columns` must name exactly one column per real column
  /// (`SQLError.columns`, the CTE/view arity fault) and be case-insensitively
  /// unique (`SQLError.duplicate`, so a shadowed rename is not silently
  /// unreachable) — the same rules a CTE's/view's column list obeys, applied
  /// where the relation's resolved width is known.
  internal func renamed(_ columns: Array<String>)
      throws(SQLError) -> Schema {
    guard !columns.isEmpty else { return self }
    guard columns.count == width else {
      throw .columns(expected: width, got: columns.count)
    }
    var seen = Set<String>()
    for column in columns where !seen.insert(column.lowercased()).inserted {
      throw .duplicate(column)
    }
    return Schema(width: width, extent: extent, names: columns,
                  types: types, virtuals: virtuals)
  }

  /// The ordinal of the column named `name`, or `nil` if absent.
  ///
  /// A real column resolves against `names` to an ordinal `< width`; a virtual
  /// column resolves against `virtuals` to its ordinal `width + i`. The real
  /// lookup wins, so a relation never hides a real column behind a virtual
  /// name. The match is case-insensitive, as a metadata source's column names
  /// are (`TypeName`, `Id`); a schema never carries two names differing only in
  /// case, so the match stays unambiguous.
  internal func ordinal(of name: String) -> Int? {
    let folded = name.lowercased()
    for index in names.indices where names[index].lowercased() == folded {
      return index
    }
    for index in virtuals.indices where virtuals[index].lowercased() == folded {
      return width + index
    }
    return nil
  }
}

extension Table where Self: ~Escapable {
  /// The resolution schema of this base table: its real `names` below `width`,
  /// its `virtuals` at and past it, with `width`/`extent` gating a `SELECT *`
  /// and the join split exactly as the table reports them.
  internal borrowing func schema() -> Schema {
    Schema(width: width, extent: extent, names: names, types: types,
           virtuals: virtuals)
  }
}

extension View {
  /// The resolution schema of this view: its columns in projection order, no
  /// virtual column.
  ///
  /// A view's column types are not known without compiling its query, so its
  /// schema types every column integral — the same default a base table without
  /// a typed schema advertises. Resolution never reads `types`; only the
  /// metadata surfaces do, and they see a view's columns through the base
  /// relations they select from.
  internal func schema() -> Schema {
    Schema(width: columns.count, extent: columns.count, names: columns,
           types: Array(repeating: .integer, count: columns.count),
           virtuals: [])
  }
}
