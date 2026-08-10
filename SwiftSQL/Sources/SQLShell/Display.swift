// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The cell-display and quote-unwrapping helpers a shell shares — how a typed
// `Value` prints in a box cell, and how a single-quoted literal is unwrapped.

extension Value {
  /// This typed cell's display string — a `NULL` as the empty string, the way
  /// `sqlite3`'s list mode shows it.
  public var display: String {
    switch self {
    case .null:                 ""
    case let .integer(integer): "\(integer)"
    // A double renders through Swift's default `Double` description — the
    // shortest decimal that round-trips to the same binary64 — so it is
    // lossless and keeps a `.0` on a whole value (`1.0`, not `1`), marking the
    // cell approximate-numeric rather than an integer.
    case let .double(double):   "\(double)"
    case let .text(text):       text
    case let .boolean(boolean): boolean ? "TRUE" : "FALSE"
    // A blob renders as a lowercase-hex `x'…'` literal — lowercase `x` and
    // digits, an empty blob as `x''` — the way `sqlite3` shows a BLOB cell.
    case let .blob(bytes):      "x'" + Value.hex(bytes) + "'"
    }
  }

  /// `bytes` as a lowercase-hex string — each byte two lowercase nibbles, high
  /// nibble first, so a byte's width is fixed and its leading zero is kept.
  private static func hex(_ bytes: Array<UInt8>) -> String {
    let digits = Array("0123456789abcdef")
    var hex = ""
    hex.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      hex.append(digits[Int(byte >> 4)])
      hex.append(digits[Int(byte & 0x0f)])
    }
    return hex
  }
}

/// The body of the single-quoted literal `text` opens with — from its first
/// `'` to the matching close, with a doubled `''` unescaped to one `'`. The
/// empty string when `text` does not open with a `'`. A run past the close (a
/// `'` not doubled) ends the body; any text after it is ignored.
public func unquote(_ text: String) -> String {
  guard text.first == "'" else { return "" }
  var body = ""
  var index = text.index(after: text.startIndex)
  while index < text.endIndex {
    let character = text[index]
    if character == "'" {
      let next = text.index(after: index)
      // A doubled `''` is one literal `'`; a lone `'` closes the body.
      guard next < text.endIndex, text[next] == "'" else { break }
      body.append("'")
      index = text.index(after: next)
      continue
    }
    body.append(character)
    index = text.index(after: index)
  }
  return body
}
