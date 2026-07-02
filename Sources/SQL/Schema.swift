// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A relation's name-resolution surface, lifted off the live data source.
///
/// Compilation resolves a column name to an ordinal, classifies a projection,
/// and lowers a predicate using only a relation's `width`, its `extent`, and its
/// name → ordinal map — never its `bound` seekability or its `cursor`, which the
/// optimiser and executor re-read from the live source by name. A `Schema` is
/// that escapable resolution surface, pure data: a base `Table` projects to one
/// (its real `names` below `width`, its `virtuals` at and past it), and a
/// compiled `View` projects to one too (its `columns` in projection order, no
/// virtual column). Lifting resolution onto a `Schema` lets a join resolve a
/// base table against a view uniformly — the two live sources need not share a
/// type, only a schema.
internal struct Schema {
  /// The real columns — the extent of a `SELECT *` projection.
  internal let width: Int

  /// One past the highest ordinal the relation can address — its real `width`
  /// plus any virtual columns. A view exposes none, so its `extent` is `width`.
  internal let extent: Int

  /// The real column names at their ordinals `0 ..< width`.
  internal let names: Array<String>

  /// The virtual column names at their ordinals `width ..< extent` — virtual
  /// `i` sits at ordinal `width + i`. A view supplies none.
  internal let virtuals: Array<String>

  internal init(width: Int, extent: Int, names: Array<String>,
                virtuals: Array<String>) {
    self.width = width
    self.extent = extent
    self.names = names
    self.virtuals = virtuals
  }

  /// The ordinal of the column named `name`, or `nil` if absent.
  ///
  /// A real column resolves against `names` to an ordinal `< width`; a virtual
  /// column resolves against `virtuals` to its ordinal `width + i`. The real
  /// lookup wins, so a relation never hides a real column behind a virtual name.
  /// The match is case-insensitive, as a metadata source's column names are
  /// (`TypeName`, `Id`); a schema never carries two names differing only in
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
    Schema(width: width, extent: extent, names: names, virtuals: virtuals)
  }
}

extension View {
  /// The resolution schema of this view: its columns in projection order, no
  /// virtual column.
  internal func schema() -> Schema {
    Schema(width: columns.count, extent: columns.count, names: columns,
           virtuals: [])
  }
}
