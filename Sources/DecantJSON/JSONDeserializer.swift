// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// A `Deserializer` that parses JSON bytes and drives a type's read.
///
/// The read is type-driven: the type names each field's type and this
/// deserializer reads that value at the current position. JSON is
/// self-describing, but the type still dictates the read; the format's
/// structure is used only to consume the object keys and separators the type
/// does not carry, so a structure reads its fields positionally, matching the
/// write side's declaration order.
///
/// It wraps a `~Escapable` `JSONScanner` over the borrowed input and layers a
/// container-context stack that consumes JSON's `{`/`}`, `[`/`]`, and the
/// key/`:`/`,` separators around each value the type asks for. It is therefore
/// `~Escapable` and `~Copyable`, threaded `inout` through the recursive read.
///
/// String reads are zero-copy where they can be: a clean literal is read
/// through the scanner's borrowed path and copied to an owned `String` only at
/// the escape boundary (the value must escape the borrow), while an escaped
/// literal was already unescaped into an owned buffer. The `withString` entry
/// exposes the borrow-vs-own decision so a caller that stays in scope pays no
/// copy for clean text.
///
/// Every method is `@inlinable` so a cross-module caller specializes the whole
/// read tree.

/// A container the read is currently inside, tracking the separator state so
/// each value read consumes the right JSON punctuation before it.
@usableFromInline
internal enum JSONContext: Sendable {
  /// Inside an object; `first` gates whether a `,` precedes the next key.
  case object(first: Bool)
  /// Inside an array with `remaining` elements still to read; `first` gates the
  /// leading `,`.
  case array(remaining: Int, first: Bool)
}

public struct JSONDeserializer: ~Escapable, ~Copyable {
  public typealias Failure = JSONError

  /// The byte scanner; `@usableFromInline` so the `@inlinable` methods reach
  /// it across the module boundary.
  @usableFromInline
  internal var scanner: JSONScanner

  /// The open-container stack. An owned `Array` is fine on a `~Escapable`
  /// value; only the scanner's `RawSpan` makes `self` non-escapable.
  @usableFromInline
  internal var contexts: Array<JSONContext>

  /// Set when `some` has already consumed the enclosing separator and
  /// positioned the cursor at a present value, so the wrapped value's own read
  /// must NOT consume a separator again. The next `prelude` clears it and
  /// returns without touching the cursor.
  @usableFromInline
  internal var primed: Bool

  /// Wraps a borrowed input span.
  @inlinable
  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    scanner = JSONScanner(bytes)
    contexts = []
    primed = false
  }

  // MARK: - Separator bookkeeping

  /// Consumes the punctuation that precedes the next value the type asks for,
  /// according to the enclosing container. For an object this is the (optional)
  /// `,`, the key string, and the `:`; for an array the (optional) `,`. An
  /// exhausted array is closed here so a following value at the parent level
  /// starts clean.
  @inlinable
  internal mutating func prelude() throws(JSONError) {
    if primed {
      primed = false
      return
    }
    try close()
    guard let context = contexts.last else { return }
    switch context {
    case let .object(first):
      if !first {
        try scanner.expect(UInt8(ascii: ","), ",")
      }
      try scanner.string(borrowed: { _ throws(JSONError) in },
                         owned: { _ throws(JSONError) in })
      try scanner.expect(UInt8(ascii: ":"), ":")
      contexts[contexts.count - 1] = .object(first: false)
    case let .array(remaining, first):
      if !first {
        try scanner.expect(UInt8(ascii: ","), ",")
      }
      contexts[contexts.count - 1] =
          .array(remaining: remaining - 1, first: false)
    }
  }

  /// Closes any array at the top of the stack whose elements are all consumed,
  /// eating its `]`; repeats so nested exhausted arrays unwind together.
  @inlinable
  internal mutating func close() throws(JSONError) {
    while case let .array(remaining, _)? = contexts.last, remaining == 0 {
      try scanner.expect(UInt8(ascii: "]"), "]")
      contexts.removeLast()
    }
  }

  // MARK: - Zero-copy string entry

  /// Reads a JSON string, yielding it to `body` as a borrowed `RawSpan` for a
  /// clean literal (zero copy) or as owned `String` bytes for an escaped one,
  /// and reports which path ran. A caller that consumes within the closure pays
  /// no copy for clean text; the public `string` sits on top of it and copies
  /// to owned at the escape boundary.
  @inlinable
  public mutating func withString(_ body: (RawSpan, JSONStringForm)
                                       throws(JSONError) -> Void)
      throws(JSONError) {
    try prelude()
    var captured = Array<UInt8>()
    let form = try scanner.string(borrowed: {
      span throws(JSONError) in try body(span, .borrowed)
    }, owned: {
      text throws(JSONError) in captured = Array(text.utf8)
    })
    guard case .owned = form else { return }
    let span = captured.span
    try body(span.bytes, .owned)
  }
}

// MARK: - Deserializer conformance

extension JSONDeserializer: Deserializer {
  @inlinable
  public mutating func integer<T: FixedWidthInteger>(_: T.Type)
      throws(JSONError) -> T {
    try prelude()
    let range = try scanner.number()
    let text = scanner.slice(range)
    guard let value = T(text) else {
      throw .number(offset: range.lowerBound)
    }
    return value
  }

  @inlinable
  public mutating func bool() throws(JSONError) -> Bool {
    try prelude()
    scanner.skip()
    switch scanner.peek() {
    case UInt8(ascii: "t"):
      try scanner.keyword("true")
      return true
    case UInt8(ascii: "f"):
      try scanner.keyword("false")
      return false
    default:
      throw .mismatch(expected: "bool", offset: scanner.offset)
    }
  }

  @inlinable
  public mutating func double() throws(JSONError) -> Double {
    try prelude()
    scanner.skip()
    if scanner.peek() == UInt8(ascii: "n") {
      try scanner.keyword("null")
      return .nan
    }
    let range = try scanner.number()
    guard let value = Double(scanner.slice(range)) else {
      throw .number(offset: range.lowerBound)
    }
    return value
  }

  @inlinable
  public mutating func string() throws(JSONError) -> String {
    try prelude()
    var result = ""
    let offset = scanner.offset
    try scanner.string(borrowed: { span throws(JSONError) in
      // Clean literal: build the `String` in one bulk copy directly from the
      // borrowed bytes — view the raw span as `UInt8`, validate it as UTF-8,
      // and copy the whole run at once. No per-byte load, no scratch `Array`.
      let bytes = Span<UInt8>(_bytes: span)
      let utf8: UTF8Span
      do {
        utf8 = try UTF8Span(validating: bytes)
      } catch {
        throw JSONError.encoding(offset: offset)
      }
      result = String(copying: utf8)
    }, owned: { text throws(JSONError) in result = text })
    return result
  }

  @inlinable
  public mutating func bytes() throws(JSONError) -> Array<UInt8> {
    let count = try count()
    var bytes = Array<UInt8>()
    bytes.reserveCapacity(count)
    for _ in 0 ..< count {
      try bytes.append(integer(UInt8.self))
    }
    try close()
    return bytes
  }

  @inlinable
  public mutating func some() throws(JSONError) -> Bool {
    // Consume the enclosing separator/key now, then peek the value byte. A
    // present value is left in place and the deserializer is `primed` so the
    // wrapped read does not consume the separator a second time; a `null` is
    // consumed here and reported absent.
    try prelude()
    scanner.skip()
    guard let byte = scanner.peek() else { throw .truncated }
    guard byte == UInt8(ascii: "n") else {
      primed = true
      return true
    }
    try scanner.keyword("null")
    return false
  }

  @inlinable
  public mutating func count() throws(JSONError) -> Int {
    try prelude()
    try scanner.expect(UInt8(ascii: "["), "[")
    let count = try tally()
    contexts.append(.array(remaining: count, first: true))
    if count == 0 {
      try close()
    }
    return count
  }

  @inlinable
  public mutating func structure(_ name: StaticString, fields count: Int)
      throws(JSONError) {
    try prelude()
    try scanner.expect(UInt8(ascii: "{"), "{")
    contexts.append(.object(first: true))
  }

  @inlinable
  public mutating func end() throws(JSONError) {
    try close()
    try scanner.expect(UInt8(ascii: "}"), "}")
    contexts.removeLast()
  }

  /// Counts the elements of the array whose `[` was just consumed, by scanning
  /// a throwaway copy of the cursor over balanced values — JSON arrays are not
  /// length-prefixed, but the core's `count` needs the count up front.
  @inlinable
  internal mutating func tally() throws(JSONError) -> Int {
    var probe = JSONScanner(scanner.bytes)
    probe.offset = scanner.offset
    probe.skip()
    if probe.peek() == UInt8(ascii: "]") {
      return 0
    }
    var count = 1
    try probe.value()
    while true {
      probe.skip()
      switch probe.peek() {
      case UInt8(ascii: ","):
        probe.offset += 1
        try probe.value()
        count += 1
      case UInt8(ascii: "]"):
        return count
      case .none:
        throw .truncated
      case let .some(byte):
        throw .unexpected(byte, offset: probe.offset, expected: ", or ]")
      }
    }
  }
}
