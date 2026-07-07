// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQLEngine

// MARK: - Display width

extension Character {
  /// This character's width in terminal display columns — `0` for a combining
  /// mark or a zero-width scalar, `2` for an East-Asian wide or fullwidth scalar
  /// (and emoji, which render double-width), `1` otherwise.
  ///
  /// A grapheme cluster's width is that of its first non-zero-width scalar, so a
  /// base plus its combining marks measures one column, the way a terminal draws
  /// it. This is the stdlib-only approximation the box renderer sizes columns
  /// with — WinMD identifiers are ASCII, but a text cell may hold anything, and
  /// sizing on bytes or scalar count would misalign a wide or accented cell.
  fileprivate var columns: Int {
    for scalar in unicodeScalars {
      let width = scalar.columns
      if width != 0 { return width }
    }
    return 0
  }
}

extension Unicode.Scalar {
  /// This scalar's width in terminal display columns — `0` for a combining mark
  /// or a zero-width scalar, `2` for an East-Asian wide/fullwidth scalar or an
  /// emoji, `1` otherwise.
  fileprivate var columns: Int {
    // A combining mark sits on the preceding base, adding no column of its own.
    if properties.canonicalCombiningClass != .notReordered { return 0 }
    switch value {
    case 0x0000,                            // NUL
         0x0300 ... 0x036f,                 // combining diacritical marks
         0x200b ... 0x200f,                 // zero-width space/joiners, marks
         0xfeff:                            // zero-width no-break space (BOM)
      return 0
    case 0x1100 ... 0x115f,                 // Hangul Jamo
         0x2e80 ... 0x303e,                 // CJK radicals, Kangxi, punctuation
         0x3041 ... 0x33ff,                 // Hiragana … CJK compatibility
         0x3400 ... 0x4dbf,                 // CJK Unified Ideographs Ext A
         0x4e00 ... 0x9fff,                 // CJK Unified Ideographs
         0xa000 ... 0xa4cf,                 // Yi
         0xac00 ... 0xd7a3,                 // Hangul Syllables
         0xf900 ... 0xfaff,                 // CJK Compatibility Ideographs
         0xfe30 ... 0xfe4f,                 // CJK Compatibility Forms
         0xff00 ... 0xff60,                 // fullwidth forms
         0xffe0 ... 0xffe6,                 // fullwidth signs
         0x1f300 ... 0x1faff,              // emoji, symbols & pictographs
         0x20000 ... 0x3fffd:              // CJK Unified Ideographs Ext B+
      return 2
    default:
      return 1
    }
  }
}

extension StringProtocol {
  /// This string's width in terminal display columns — the sum of its
  /// characters' `columns`, so a wide or combining cell aligns the way the
  /// terminal draws it rather than by byte or scalar count.
  fileprivate var columns: Int {
    reduce(0) { $0 + $1.columns }
  }
}

// MARK: - Box table

/// A Unicode box-drawing renderer for a query result — the `sqlite3`-style
/// `.mode box` grid.
///
/// The shell hands off a result — column `names` and the `rows` the engine
/// yields — and gets back one string: a light box-drawing table with a header
/// row over a `├─┼─┤` rule, one line per row, and a `┌─┬─┐`/`└─┴─┘` frame. Each
/// column is sized to the widest of its header and its cells, measured in
/// display columns (`String.columns`) so a wide or accented cell still aligns,
/// and every cell sits between a single space of left and right padding — the
/// clean, conventional style `sqlite3` renders and `psql`'s unicode border
/// draws. A `NULL` (or an empty text) cell renders as the empty string, the way
/// the shell's list mode shows it; an empty result (no rows) renders the header
/// and frame alone, so the column names still print.
///
/// It is a stateless renderer, not a value: the one `render` static builds the
/// string and nothing outlives the call, so it is a `caseless enum` namespace
/// rather than a struct with no stored properties.
internal enum Box {
  /// The single space of padding on each side of every cell.
  private static let padding = " "

  /// Renders `rows` under `names` as a `.mode box` grid — a framed, header-ruled
  /// Unicode table sized to each column's widest display cell.
  ///
  /// The width of column `i` is the widest of `names[i]` and every `rows[_][i]`
  /// cell's display string, measured in display columns; each cell is padded to
  /// that width between one space on each side. A row shorter than `names` (a
  /// short arm) pads the missing trailing cells empty, and a cell past `names`
  /// is ignored, so a ragged result still frames cleanly. With no rows the
  /// header and frame print alone.
  internal static func render(_ names: Array<String>,
                              _ rows: Array<Array<Value>>) -> String {
    // The display text of every cell, sized alongside its header so a column is
    // as wide as its widest occupant.
    let cells = rows.map { row in
      names.indices.map { column in
        column < row.count ? row[column].display : ""
      }
    }
    let widths = names.indices.map { column in
      let header = names[column].columns
      let body = cells.map { $0[column].columns }.max() ?? 0
      return Swift.max(header, body)
    }

    var lines = Array<String>()
    lines.append(rule("┌", "┬", "┐", widths))
    lines.append(record(names, widths))
    lines.append(rule("├", "┼", "┤", widths))
    for row in cells { lines.append(record(row, widths)) }
    lines.append(rule("└", "┴", "┘", widths))
    return lines.joined(separator: "\n")
  }

  /// One data or header record — each cell padded to its column `width` between
  /// a space on each side, the cells joined by `│` and framed by `│`.
  private static func record(_ cells: Array<String>,
                             _ widths: Array<Int>) -> String {
    let columns = widths.indices.map { column in
      let cell = column < cells.count ? cells[column] : ""
      return padding + pad(cell, widths[column]) + padding
    }
    return "│" + columns.joined(separator: "│") + "│"
  }

  /// A horizontal frame rule — `left`, then each column's `─` run (its `width`
  /// plus the two padding spaces) joined by `mid`, closed by `right`.
  private static func rule(_ left: String, _ mid: String, _ right: String,
                           _ widths: Array<Int>) -> String {
    let segments = widths.map { String(repeating: "─", count: $0 + 2) }
    return left + segments.joined(separator: mid) + right
  }

  /// `text` right-padded with spaces to `width` display columns; already at or
  /// past `width`, it is returned unchanged. The pad counts the shortfall in
  /// display columns, so a wide or combining cell aligns the way it is drawn.
  private static func pad(_ text: String, _ width: Int) -> String {
    text + String(repeating: " ", count: Swift.max(0, width - text.columns))
  }
}
