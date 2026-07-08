// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The low-level byte scanner the JSON deserializer drives — a cursor over the
/// borrowed input with the lexical primitives (whitespace, keywords, strings,
/// numbers, balanced-value skip) the read calls into.
///
/// It is `~Escapable` and `~Copyable`: it holds a borrowed `RawSpan` view into
/// the input and a mutating `offset`, so no copy of the input is made and it
/// never vends a borrowed view that outlives a step. `JSONDeserializer` wraps
/// it and adds the container state that turns the grammar into the type-driven
/// read surface the core defines.
///
/// The string primitive is the zero-copy crux: `string` reports whether the
/// scanned literal is escape-free, and a clean literal is handed back as a
/// borrowed sub-`RawSpan` of the input with no copy; only a literal carrying an
/// escape is unescaped into an owned buffer. Every method is `@inlinable` so a
/// cross-module caller specializes the whole scan.

/// The kind a scanned string literal takes, surfaced so a caller (and a test)
/// can observe whether the fast borrowed path was taken.
public enum JSONStringForm: Sendable, Equatable {
  /// The literal was escape-free: its bytes ARE the string and were returned as
  /// a borrowed view into the input — zero copy.
  case borrowed
  /// The literal carried an escape (`\n`, `\uXXXX`, a surrogate pair): it was
  /// unescaped into an owned buffer the scanner built.
  case owned
}

/// A scanned clean literal handed back as a borrowed sub-span — the zero-copy
/// path a caller stays inside.
@usableFromInline
internal typealias Borrowed = (RawSpan) throws(JSONError) -> Void

/// A scanned escaped literal handed back as an owned, unescaped `String`.
@usableFromInline
internal typealias Owned = (String) throws(JSONError) -> Void

public struct JSONScanner: ~Escapable, ~Copyable {
  /// The input bytes, borrowed for the scanner's lifetime.
  @usableFromInline
  internal let bytes: RawSpan

  /// The read cursor into `bytes`.
  @usableFromInline
  internal var offset: Int

  /// Wraps a borrowed span, positioned at its start.
  @inlinable
  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    self.bytes = bytes
    offset = 0
  }

  // MARK: - Cursor primitives

  /// The byte at `index` without advancing.
  @inlinable
  internal func load(_ index: Int) -> UInt8 {
    bytes.load(fromByteOffset: index, as: UInt8.self)
  }

  /// The byte at the cursor without advancing, or nil at the end.
  @inlinable
  internal func peek() -> UInt8? {
    offset < bytes.byteCount ? load(offset) : nil
  }

  /// Advances past runs of JSON whitespace (space, tab, CR, LF).
  @inlinable
  internal mutating func skip() {
    while offset < bytes.byteCount {
      switch load(offset) {
      case 0x20, 0x09, 0x0a, 0x0d:
        offset += 1
      default:
        return
      }
    }
  }

  /// Consumes the byte `expected` after skipping whitespace, or throws.
  @inlinable
  internal mutating func expect(_ expected: UInt8, _ what: StaticString)
      throws(JSONError) {
    skip()
    guard let byte = peek() else { throw .truncated }
    guard byte == expected else {
      throw .unexpected(byte, offset: offset, expected: what)
    }
    offset += 1
  }

  // MARK: - Keywords

  /// Consumes a bare keyword (`true`/`false`/`null`) after whitespace.
  @inlinable
  internal mutating func keyword(_ word: StaticString) throws(JSONError) {
    skip()
    for expected in word.utf8Start ..< word.utf8Start + word.utf8CodeUnitCount {
      let want = expected.pointee
      guard offset < bytes.byteCount else { throw .truncated }
      guard load(offset) == want else {
        throw .unexpected(load(offset), offset: offset, expected: word)
      }
      offset += 1
    }
  }

  // MARK: - Numbers

  /// Scans a numeric literal, returning its byte range so the caller can parse
  /// it as the width the type dictates.
  @inlinable
  internal mutating func number() throws(JSONError) -> Range<Int> {
    skip()
    let start = offset
    if peek() == UInt8(ascii: "-") {
      offset += 1
    }
    while let byte = peek(),
        digit(byte) || byte == UInt8(ascii: ".") ||
        byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") ||
        byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
      offset += 1
    }
    guard offset > start else {
      throw .unexpected(peek() ?? 0, offset: offset, expected: "number")
    }
    return start ..< offset
  }

  /// Copies the bytes of `range` out as an owned `String` for numeric parsing.
  /// A numeric literal is ASCII, so its sub-span validates as UTF-8 and is
  /// copied out in one bulk step rather than byte by byte.
  @inlinable
  internal func slice(_ range: Range<Int>) -> String {
    let view = Span<UInt8>(_bytes: bytes.extracting(range))
    guard let utf8 = try? UTF8Span(validating: view) else { return "" }
    return String(copying: utf8)
  }

  /// Whether `byte` is an ASCII decimal digit.
  @inlinable
  internal func digit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }

  // MARK: - Strings (the zero-copy crux)

  /// Scans a `"…"` string. A clean (escape-free) literal is handed to
  /// `borrowed` as a BORROWED sub-span of the input — zero copy; a literal with
  /// escapes is unescaped into an owned buffer handed to `owned`. The
  /// `JSONStringForm` return reports which path ran so a caller (and a test)
  /// can observe the borrow-vs-own decision.
  @inlinable
  @discardableResult
  internal mutating func string(borrowed: Borrowed, owned: Owned)
      throws(JSONError) -> JSONStringForm {
    try expect(UInt8(ascii: "\""), "string")
    let start = offset
    var escaped = false
    // First pass: find the closing quote and whether an escape is present,
    // without materializing anything.
    while true {
      guard offset < bytes.byteCount else { throw .truncated }
      let byte = load(offset)
      if byte == UInt8(ascii: "\"") {
        break
      }
      if byte == UInt8(ascii: "\\") {
        escaped = true
        offset += 1
        guard offset < bytes.byteCount else { throw .truncated }
      }
      offset += 1
    }
    let end = offset
    offset += 1                                     // past the closing quote
    if escaped {
      try owned(unescape(start ..< end))
      return .owned
    }
    try borrowed(bytes.extracting(start ..< end))
    return .borrowed
  }

  /// Unescapes the literal spanning `range` (exclusive of quotes) into an owned
  /// `String`, decoding `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and
  /// `\uXXXX` (combining a surrogate pair past the BMP).
  ///
  /// The result is assembled as UTF-8 bytes in a single buffer and decoded to a
  /// `String` once at the end: a clean byte is appended verbatim (it is already
  /// UTF-8) and an escape is appended as its UTF-8 encoding. This keeps the
  /// clean runs a bulk byte append rather than a per-scalar re-decode.
  @inlinable
  internal func unescape(_ range: Range<Int>) throws(JSONError) -> String {
    var bytes = Array<UInt8>()
    bytes.reserveCapacity(range.count)
    var index = range.lowerBound
    while index < range.upperBound {
      let byte = load(index)
      guard byte == UInt8(ascii: "\\") else {                // clean byte
        bytes.append(byte)
        index += 1
        continue
      }
      index += 1
      guard index < range.upperBound else { throw .escape(offset: index) }
      switch load(index) {
      case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
      case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
      case UInt8(ascii: "/"): bytes.append(UInt8(ascii: "/"))
      case UInt8(ascii: "b"): bytes.append(0x08)
      case UInt8(ascii: "f"): bytes.append(0x0c)
      case UInt8(ascii: "n"): bytes.append(0x0a)
      case UInt8(ascii: "r"): bytes.append(0x0d)
      case UInt8(ascii: "t"): bytes.append(0x09)
      case UInt8(ascii: "u"):
        let (scalar, next) = try scalar(after: index, in: range)
        for unit in scalar.utf8 {
          bytes.append(unit)
        }
        index = next
        continue
      default:
        throw .escape(offset: index)
      }
      index += 1
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Decodes a `\uXXXX` escape whose `u` is at `index`, combining a high/low
  /// surrogate pair into one scalar; returns the scalar and the index just past
  /// the consumed escape(s).
  @inlinable
  internal func scalar(after index: Int, in range: Range<Int>)
      throws(JSONError) -> (Unicode.Scalar, Int) {
    let high = try hex(at: index + 1, in: range)
    var cursor = index + 5
    if high >= 0xd800 && high <= 0xdbff {
      guard cursor + 1 < range.upperBound,
          load(cursor) == UInt8(ascii: "\\"),
          load(cursor + 1) == UInt8(ascii: "u") else {
        throw .surrogate(offset: index)
      }
      let low = try hex(at: cursor + 2, in: range)
      guard low >= 0xdc00 && low <= 0xdfff else {
        throw .surrogate(offset: index)
      }
      let combined = 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)
      cursor += 6
      guard let scalar = Unicode.Scalar(combined) else {
        throw .surrogate(offset: index)
      }
      return (scalar, cursor)
    }
    guard high < 0xdc00 || high > 0xdfff,
        let scalar = Unicode.Scalar(high) else {
      throw .surrogate(offset: index)
    }
    return (scalar, cursor)
  }

  /// Reads four hex digits at `index` as a UInt32, bounds-checked against
  /// `range`.
  @inlinable
  internal func hex(at index: Int, in range: Range<Int>)
      throws(JSONError) -> UInt32 {
    guard index + 4 <= range.upperBound else { throw .escape(offset: index) }
    var value: UInt32 = 0
    for cursor in index ..< index + 4 {
      let byte = load(cursor)
      let nibble: UInt32 = switch byte {
      case UInt8(ascii: "0") ... UInt8(ascii: "9"):
        UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a") ... UInt8(ascii: "f"):
        UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A") ... UInt8(ascii: "F"):
        UInt32(byte - UInt8(ascii: "A") + 10)
      default:
        0xffff_ffff
      }
      guard nibble != 0xffff_ffff else { throw .escape(offset: index) }
      value = value << 4 | nibble
    }
    return value
  }

  // MARK: - Balanced skip (value / element counting)

  /// Skips one complete JSON value (scalar or balanced compound) without
  /// materializing it.
  @inlinable
  internal mutating func value() throws(JSONError) {
    skip()
    guard let byte = peek() else { throw .truncated }
    switch byte {
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      try compound()
    case UInt8(ascii: "\""):
      try string(borrowed: { _ throws(JSONError) in },
                 owned: { _ throws(JSONError) in })
    case UInt8(ascii: "t"):
      try keyword("true")
    case UInt8(ascii: "f"):
      try keyword("false")
    case UInt8(ascii: "n"):
      try keyword("null")
    default:
      _ = try number()
    }
  }

  /// Skips a balanced `{…}`/`[…]`, tracking nesting and skipping strings so a
  /// brace inside a string does not miscount.
  @inlinable
  internal mutating func compound() throws(JSONError) {
    var depth = 0
    repeat {
      skip()
      guard let byte = peek() else { throw .truncated }
      switch byte {
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        depth += 1
        offset += 1
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        depth -= 1
        offset += 1
      case UInt8(ascii: "\""):
        try string(borrowed: { _ throws(JSONError) in },
                   owned: { _ throws(JSONError) in })
      default:
        offset += 1
      }
    } while depth > 0
  }
}
