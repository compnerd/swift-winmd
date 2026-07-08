// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// A `Serializer` that encodes any value to JSON text, straight into a `Sink`,
/// in a single pass with no intermediate tree.
///
/// The mapping is the obvious one — a structure becomes an object, a sequence
/// an array, and the scalar leaves become JSON string/number/bool/null — and
/// every leaf writes its bytes directly through the sink, so the value's
/// structure IS the traversal. It is generic over the `Sink` it owns,
/// `~Copyable`, and threaded by consume/return so a throw on a compound path
/// never leaves a half-consumed slot.
///
/// Framing (`{`/`}`, `[`/`]`, the separating `,`/`:`) is the format's whole
/// job here; the sub-serializers defer the opening bracket to the first
/// `element`/`field` (or to `end` for an empty compound) so the openers stay
/// non-throwing, matching the core's `~Copyable` reclaim contract.
///
/// Every method is `@inlinable`, so a cross-module caller specializes the whole
/// encode tree to straight-line code.

// MARK: - String escaping

/// JSON string-escaping helpers shared by the scalar and key writers.
public enum JSONEscape {
  /// Appends `value` to `sink` as a quoted, escaped JSON string. The mandatory
  /// escapes (`"`, `\`, and the C0 control range) go out as their short forms
  /// where JSON defines one (`\n`, `\t`, …) and as `\u00XX` otherwise; every
  /// other scalar — including non-ASCII — is emitted as its raw UTF-8, which is
  /// valid JSON and keeps clean text byte-identical on a round-trip.
  ///
  /// The write scans the string's UTF-8 directly over its `utf8Span` for the
  /// next byte that needs a JSON escape, and bulk-appends the whole clean run
  /// that precedes it as a `Span` in a single `Sink.append` before emitting the
  /// escape and resuming — so a string with no escapes is one bulk copy of the
  /// whole run and an escaped one copies each clean run whole rather than one
  /// byte at a time. Both the scan cursor and the run bounds are plain integer
  /// offsets into the span, so extending a run is O(1) with no per-byte index
  /// arithmetic; a run rides out as a sub-`Span` (`span.extracting`), which the
  /// `Span`-taking `Sink.append` bulk-copies. The bytes are the string's own,
  /// borrowed in place through `utf8Span` — no intermediate `Array` copy, and
  /// no unsafe pointer.
  @inlinable
  public static func write<S: Sink>(_ value: String, into sink: inout S)
      throws(DecantError) {
    try sink.append(UInt8(ascii: "\""))
    let utf8 = value.utf8Span
    let bytes = utf8.span
    let count = bytes.count
    var runStart = 0                        // start of the pending clean run
    var offset = 0
    while offset < count {
      let byte = bytes[offset]
      // A byte at or above 0x20 that is neither `"` nor `\` needs no escape, so
      // it extends the current clean run; only the exceptions break it. The
      // short escapes are `\` plus one marker byte; a bare control takes the
      // six-byte `\u00XX` form. Each is emitted byte by byte rather than
      // through an `Array` literal, since a fresh heap allocation at every
      // escape is what a densely escaped string cannot afford — and escapes
      // are the rare case anyway, the clean bytes between them still riding
      // out in one bulk slice.
      let marker: UInt8
      switch byte {
      case UInt8(ascii: "\""): marker = UInt8(ascii: "\"")
      case UInt8(ascii: "\\"): marker = UInt8(ascii: "\\")
      case 0x08:               marker = UInt8(ascii: "b")
      case 0x0c:               marker = UInt8(ascii: "f")
      case 0x0a:               marker = UInt8(ascii: "n")
      case 0x0d:               marker = UInt8(ascii: "r")
      case 0x09:               marker = UInt8(ascii: "t")
      case 0x00 ... 0x1f:      marker = 0            // no short form
      default:
        offset += 1
        continue
      }
      if runStart < offset {
        try sink.append(bytes.extracting(runStart ..< offset))
      }
      if marker == 0 {
        try unicode(byte, into: &sink)
      } else {
        try sink.append(UInt8(ascii: "\\"))
        try sink.append(marker)
      }
      offset += 1
      runStart = offset
    }
    if runStart < count {
      try sink.append(bytes.extracting(runStart ..< count))
    }
    try sink.append(UInt8(ascii: "\""))
  }

  /// Appends the six-byte `\u00XX` escape for a C0 control byte directly, byte
  /// by byte, so no per-escape `Array` is allocated.
  @inlinable
  internal static func unicode<S: Sink>(_ byte: UInt8, into sink: inout S)
      throws(DecantError) {
    func hex(_ nibble: UInt8) -> UInt8 {
      nibble < 10 ? UInt8(ascii: "0") + nibble
                  : UInt8(ascii: "a") + (nibble - 10)
    }
    try sink.append(UInt8(ascii: "\\"))
    try sink.append(UInt8(ascii: "u"))
    try sink.append(UInt8(ascii: "0"))
    try sink.append(UInt8(ascii: "0"))
    try sink.append(hex(byte >> 4))
    try sink.append(hex(byte & 0x0f))
  }

  /// Appends `text` to `sink` as raw UTF-8 with no quoting or escaping, over
  /// its `utf8Span` in one bulk copy — the writer for a JSON literal (a number,
  /// `true`/`false`/`null`) whose bytes are already valid and need no escape,
  /// so it skips both the scan and the intermediate `Array` copy.
  @inlinable
  public static func raw<S: Sink>(_ text: String, into sink: inout S)
      throws(DecantError) {
    let utf8 = text.utf8Span
    try sink.append(utf8.span)
  }
}

// MARK: - Serializer

/// The JSON serializer, generic over its `Sink`.
public struct JSONSerializer<Output: Sink>: Serializer, ~Copyable {
  public typealias Failure = DecantError

  /// The sink this serializer writes into; `@usableFromInline` so the
  /// `@inlinable` methods reach it across the module boundary.
  @usableFromInline
  internal var sink: Output

  /// Wraps a sink; the caller reclaims it with `finish`.
  @inlinable
  public init(_ sink: consuming Output) {
    self.sink = sink
  }

  /// Surrenders the filled sink to the caller.
  @inlinable
  public consuming func finish() -> Output {
    sink
  }

  @inlinable
  public mutating func serialize(_ value: Bool) throws(DecantError) {
    try JSONEscape.raw(value ? "true" : "false", into: &sink)
  }

  @inlinable
  public mutating func serialize<T: FixedWidthInteger>(_ value: T)
      throws(DecantError) {
    try JSONEscape.raw(String(value), into: &sink)
  }

  @inlinable
  public mutating func serialize(_ value: Double) throws(DecantError) {
    // A non-finite double has no JSON literal; emit null, matching the common
    // convention (JSON has no NaN/Infinity), so the output stays valid.
    let text = if value.isFinite { String(value) } else { "null" }
    try JSONEscape.raw(text, into: &sink)
  }

  @inlinable
  public mutating func serialize(_ value: String) throws(DecantError) {
    try JSONEscape.write(value, into: &sink)
  }

  @inlinable
  public mutating func serialize(bytes: some Sequence<UInt8>)
      throws(DecantError) {
    // Bytes ride JSON as an array of numeric octets — no base64 dependency,
    // and it round-trips through the sequence read path (`bytes()` reads an
    // array of `UInt8`). Framed directly rather than through `sequence`, which
    // consumes `self` (illegal from a `mutating` method).
    try sink.append(UInt8(ascii: "["))
    var first = true
    for byte in bytes {
      if !first {
        try sink.append(UInt8(ascii: ","))
      }
      first = false
      try JSONEscape.raw(String(byte), into: &sink)
    }
    try sink.append(UInt8(ascii: "]"))
  }

  @inlinable
  public mutating func null() throws(DecantError) {
    try JSONEscape.raw("null", into: &sink)
  }

  @inlinable
  public mutating func some() throws(DecantError) {}

  @inlinable
  public consuming func sequence(count: Int?)
      -> JSONSequenceSerializer<Output> {
    JSONSequenceSerializer(self)
  }

  @inlinable
  public consuming func structure(_ name: StaticString, fields count: Int)
      -> JSONStructureSerializer<Output> {
    JSONStructureSerializer(self)
  }
}

/// The JSON array sub-serializer: `[`, elements separated by `,`, then `]`.
/// It owns the parent serializer for the three-phase write and returns it from
/// `end`.
public struct JSONSequenceSerializer<Output: Sink>: SequenceSerializer,
    ~Copyable {
  public typealias Failure = DecantError
  public typealias Parent = JSONSerializer<Output>

  /// The parent serializer, held as `Optional` so it can be moved out (leaving
  /// `.none`, a fully-initialized state) and back — the exception-safe reclaim
  /// across a throwing `element`, since `~Copyable` forbids partially
  /// reinitializing `self` on the throw path.
  @usableFromInline
  internal var serializer: JSONSerializer<Output>?

  /// Whether the next element is the first — it opens with `[` instead of `,`.
  @usableFromInline
  internal var first: Bool

  @inlinable
  internal init(_ serializer: consuming JSONSerializer<Output>) {
    self.serializer = consume serializer
    first = true
  }

  @inlinable
  public mutating func element<T: Serializable>(_ value: borrowing T)
      throws(DecantError) {
    var inner = serializer.take()!
    try inner.sink.append(UInt8(ascii: first ? "[" : ","))
    first = false
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  @inlinable
  public consuming func end() throws(DecantError) -> JSONSerializer<Output> {
    var inner = serializer.take()!
    if first {
      try inner.sink.append(UInt8(ascii: "["))
    }
    try inner.sink.append(UInt8(ascii: "]"))
    return inner
  }
}

/// The JSON object sub-serializer: `{`, `"name":value` pairs separated by
/// `,`, then `}`.
public struct JSONStructureSerializer<Output: Sink>: StructureSerializer,
    ~Copyable {
  public typealias Failure = DecantError
  public typealias Parent = JSONSerializer<Output>

  /// The parent serializer, held as `Optional` for the same exception-safe
  /// move-out/back reclaim as `JSONSequenceSerializer`.
  @usableFromInline
  internal var serializer: JSONSerializer<Output>?

  /// Whether the next field is the first — it opens with `{` instead of `,`.
  @usableFromInline
  internal var first: Bool

  @inlinable
  internal init(_ serializer: consuming JSONSerializer<Output>) {
    self.serializer = consume serializer
    first = true
  }

  @inlinable
  public mutating func field<T: Serializable>(_ name: StaticString,
                                              _ value: borrowing T)
      throws(DecantError) {
    var inner = serializer.take()!
    try inner.sink.append(UInt8(ascii: first ? "{" : ","))
    first = false
    try JSONEscape.write("\(name)", into: &inner.sink)
    try inner.sink.append(UInt8(ascii: ":"))
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  @inlinable
  public consuming func end() throws(DecantError) -> JSONSerializer<Output> {
    var inner = serializer.take()!
    if first {
      try inner.sink.append(UInt8(ascii: "{"))
    }
    try inner.sink.append(UInt8(ascii: "}"))
    return inner
  }
}
