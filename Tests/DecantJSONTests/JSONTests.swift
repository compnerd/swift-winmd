// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import Decant
import DecantMacros
import DecantJSON

// MARK: - Fixtures

/// A macro-derived struct of plain scalar fields — exercises the JSON object
/// codegen (one field per stored property, in declaration order) across the
/// module boundary the tests import.
@Serializable @Deserializable
private struct Point: Equatable {
  var x: Int32
  var y: Int32
  var label: String
}

/// A macro-derived struct nesting another struct and carrying a collection, an
/// optional, a bool, and a double — exercises the recursive walk and each JSON
/// leaf kind.
@Serializable @Deserializable
private struct Shape: Equatable {
  var origin: Point
  var vertices: Array<Point>
  var name: String?
  var closed: Bool
  var area: Double
}

/// A HAND-WRITTEN conformance over the driver surface — confirms the JSON
/// serializers are usable directly, not only through the derive.
private struct Version: Equatable {
  var major: UInt16
  var minor: UInt16
}

extension Version: Serializable {
  func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var structure =
        (consume serializer).structure("Version", fields: 2)
    try structure.field("major", major)
    try structure.field("minor", minor)
    return try structure.end()
  }
}

extension Version: Deserializable {
  static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Version
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.structure("Version", fields: 2)
    let major = try deserializer.integer(UInt16.self)
    let minor = try deserializer.integer(UInt16.self)
    try deserializer.end()
    return Version(major: major, minor: minor)
  }
}

// MARK: - Round-trip

struct RoundTripTests {
  @Test func `a macro-derived struct round-trips through JSON`() throws {
    let point = Point(x: -7, y: 42, label: "corner")
    #expect(try decode(Point.self, json: encode(json: point)) == point)
  }

  @Test func `a struct encodes to the expected JSON object text`() throws {
    let point = Point(x: 1, y: 2, label: "p")
    #expect(try encode(json: point) == #"{"x":1,"y":2,"label":"p"}"#)
  }

  @Test func `a hand-written conformance round-trips through JSON`() throws {
    let version = Version(major: 6, minor: 4)
    #expect(try decode(Version.self, json: encode(json: version)) == version)
  }

  @Test func `a nested struct round-trips through the child conformance`()
      throws {
    let shape =
        Shape(origin: Point(x: 0, y: 0, label: "o"),
              vertices: [Point(x: 1, y: 2, label: "a"),
                         Point(x: 3, y: 4, label: "b")],
              name: "triangle", closed: true, area: 6.5)
    #expect(try decode(Shape.self, json: encode(json: shape)) == shape)
  }

  @Test func `a null optional round-trips`() throws {
    let shape = Shape(origin: Point(x: 5, y: 6, label: "p"),
                      vertices: [], name: nil, closed: false, area: 0.0)
    let text = try encode(json: shape)
    #expect(text.contains(#""name":null"#))
    #expect(try decode(Shape.self, json: text) == shape)
  }

  @Test func `a present optional round-trips`() throws {
    let shape = Shape(origin: Point(x: 1, y: 1, label: "q"),
                      vertices: [], name: "square", closed: true, area: 4.0)
    #expect(try decode(Shape.self, json: encode(json: shape)) == shape)
  }

  @Test func `a collection of struct elements round-trips`() throws {
    let points = [Point(x: 1, y: 1, label: "a"),
                  Point(x: 2, y: 2, label: "bb"),
                  Point(x: 3, y: 3, label: "ccc")]
    #expect(try decode(Array<Point>.self,
                       json: encode(json: points)) == points)
  }

  @Test func `an empty object round-trips`() throws {
    let version = Version(major: 0, minor: 0)
    #expect(try decode(Version.self, json: encode(json: version)) == version)
  }

  @Test func `an empty array encodes and round-trips`() throws {
    let points: Array<Point> = []
    #expect(try encode(json: points) == "[]")
    #expect(try decode(Array<Point>.self, json: "[]") == points)
  }

  @Test func `integers of each width round-trip`() throws {
    for value in [Int32.min, -1, 0, 1, Int32.max] {
      #expect(try decode(Int32.self, json: encode(json: value)) == value)
    }
    #expect(try decode(UInt64.self,
                       json: encode(json: UInt64.max)) == UInt64.max)
  }

  @Test func `a double round-trips`() throws {
    for value in [0.0, -3.5, 2.5e10, 1.0 / 3.0] {
      #expect(try decode(Double.self, json: encode(json: value)) == value)
    }
  }
}

// MARK: - Strings

struct StringTests {
  @Test func `a string with control and quote escapes round-trips`() throws {
    let value = "line1\nline2\ttab\"quote\\slash"
    #expect(try decode(String.self, json: encode(json: value)) == value)
  }

  @Test func `an encoded newline uses the short JSON escape`() throws {
    #expect(try encode(json: "a\nb") == #""a\nb""#)
  }

  @Test func `an encoded C0 control uses a u-escape`() throws {
    #expect(try encode(json: "\u{01}") == "\"\\u0001\"")
  }

  @Test func `a unicode escape decodes to its scalar`() throws {
    #expect(try decode(String.self, json: #""é""#) == "é")
  }

  @Test func `a surrogate-pair escape decodes past the BMP`() throws {
    #expect(try decode(String.self, json: #""😀""#) == "😀")
  }

  @Test func `non-ASCII text round-trips verbatim`() throws {
    let value = "café 日本語 😀"
    #expect(try decode(String.self, json: encode(json: value)) == value)
  }

  @Test func `an empty string round-trips`() throws {
    #expect(try decode(String.self, json: #""""#) == "")
  }

  @Test func `a clean multi-byte string decodes in bulk`() throws {
    // The bulk borrowed read validates and copies the whole run at once; a
    // clean multi-byte literal must decode verbatim, not per byte.
    let value = "αβγ 日本語 😀 emoji"
    #expect(try decode(String.self, json: #""\#(value)""#) == value)
  }

  @Test func `a long clean run encodes in one bulk copy`() throws {
    // The escape scan bulk-appends the whole clean run at once; a long run
    // with no escapes must emit verbatim inside the quotes.
    let value = String(repeating: "abcABC123 日本語 ", count: 64)
    #expect(try encode(json: value) == "\"\(value)\"")
    #expect(try decode(String.self, json: encode(json: value)) == value)
  }

  @Test func `an all-escapes string encodes each escape`() throws {
    // With no clean bytes between them, every character breaks the run; the
    // scan must still emit the short escapes back to back.
    #expect(try encode(json: "\"\\\n\t\r") == #""\"\\\n\t\r""#)
    let value = "\"\\\n\t\r\u{08}\u{0c}"
    #expect(try decode(String.self, json: encode(json: value)) == value)
  }

  @Test func `the C0 control range encodes as u-escapes or short forms`()
      throws {
    // Every byte 0x00–0x1F must escape: the five short forms JSON names and a
    // `\u00XX` for the rest, all round-tripping.
    var scalars = ""
    for byte in UInt8(0x00) ... UInt8(0x1f) {
      scalars.unicodeScalars.append(Unicode.Scalar(byte))
    }
    let value = "clean\(scalars)tail"
    #expect(try decode(String.self, json: encode(json: value)) == value)
    #expect(try encode(json: "\u{00}") == "\"\\u0000\"")
    #expect(try encode(json: "\u{1f}") == "\"\\u001f\"")
    #expect(try encode(json: "\u{0b}") == "\"\\u000b\"")   // no short form
  }
}

// MARK: - Zero-copy borrow vs owned

struct BorrowTests {
  /// A clean literal must take the BORROWED path (no unescape copy); an escaped
  /// literal must take the OWNED path. `withString` reports which ran.
  @Test func `a clean string decodes via the borrowed path`() throws {
    try withString(#""hello""#) { span, form in
      #expect(form == .borrowed)
      #expect(span.byteCount == 5)
    }
  }

  @Test func `an escaped string decodes via the owned path`() throws {
    try withString(#""a\nb""#) { span, form in
      #expect(form == .owned)
      #expect(span.byteCount == 3)                   // a, LF, b
    }
  }

  @Test func `a clean multi-byte string keeps the borrowed path`() throws {
    // The bulk read still borrows a multi-byte literal; its span is the raw
    // UTF-8 run — "é" is 2 bytes and "😀" is 4, so 6 bytes.
    try withString(#""é😀""#) { span, form in
      #expect(form == .borrowed)
      #expect(span.byteCount == 6)
    }
  }

  /// Drives `withString` over a whole-document string literal.
  private func withString(_ text: String,
                          _ body: (RawSpan, JSONStringForm)
                              throws(JSONError) -> Void) throws {
    let bytes = Array(text.utf8)
    try bytes.withUnsafeBytes { buffer in
      var deserializer = JSONDeserializer(RawSpan(_unsafeBytes: buffer))
      try deserializer.withString(body)
    }
  }
}

// MARK: - Malformed input

struct MalformedTests {
  @Test func `a truncated object throws rather than crashing`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(Point.self, json: #"{"x":1,"y":2,"label":"#)
    }
  }

  @Test func `a non-numeric integer field throws`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(Point.self, json: #"{"x":"nope","y":2,"label":"p"}"#)
    }
  }

  @Test func `an unterminated string throws`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(String.self, json: #""oops"#)
    }
  }

  @Test func `a bad escape throws`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(String.self, json: #""a\xb""#)
    }
  }

  @Test func `a lone high surrogate throws`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(String.self, json: #""\uD83D""#)
    }
  }

  @Test func `trailing content after the value throws`() throws {
    #expect(throws: JSONError.self) {
      _ = try decode(Int32.self, json: "1 2")
    }
  }
}
