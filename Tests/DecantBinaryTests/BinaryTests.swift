// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import Decant
import DecantMacros
import DecantBinary

// MARK: - Round-trip helpers

/// Encodes `value` to the compact binary form over a growable sink.
private func encode<T: Serializable>(_ value: borrowing T)
    throws(DecantError) -> Array<UInt8> {
  var serializer = BinarySerializer(ArraySink())
  serializer = try value.serialize(into: serializer)
  return serializer.finish().bytes
}

/// Decodes a `T` from binary bytes, driving the read over a borrowed span so no
/// copy of the input is made.
private func decode<T: Deserializable>(_: T.Type = T.self,
                                       from bytes: borrowing Array<UInt8>)
    throws(DecantError) -> T {
  var deserializer = BinaryDeserializer(bytes.span.bytes)
  return try deserializer.decode(T.self)
}

// MARK: - Fixtures

/// A macro-derived struct of plain scalar fields — exercises the derive across
/// the module boundary the tests import.
@Serializable @Deserializable
private struct Point: Equatable {
  var x: Int32
  var y: Int32
  var label: String
}

/// A macro-derived struct nesting another struct and carrying a collection and
/// an optional — exercises the recursive walk.
@Serializable @Deserializable
private struct Shape: Equatable {
  var origin: Point
  var vertices: Array<Point>
  var name: String?
  var closed: Bool
}

/// A HAND-WRITTEN conformance over the same driver surface — confirms the
/// binary serializers are usable directly, not only through the derive.
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

// MARK: - Tests

struct RoundTripTests {
  @Test func `a macro-derived struct of plain fields round-trips`() throws {
    let point = Point(x: -7, y: 42, label: "corner")
    #expect(try decode(Point.self, from: encode(point)) == point)
  }

  @Test func `a hand-written conformance round-trips`() throws {
    let version = Version(major: 6, minor: 4)
    #expect(try decode(Version.self, from: encode(version)) == version)
  }

  @Test func `a nested struct round-trips through the child conformance`()
      throws {
    let shape =
        Shape(origin: Point(x: 0, y: 0, label: "o"),
              vertices: [Point(x: 1, y: 2, label: "a"),
                         Point(x: 3, y: 4, label: "b")],
              name: "triangle", closed: true)
    #expect(try decode(Shape.self, from: encode(shape)) == shape)
  }

  @Test func `an absent optional round-trips`() throws {
    let shape = Shape(origin: Point(x: 5, y: 6, label: "p"),
                      vertices: [], name: nil, closed: false)
    #expect(try decode(Shape.self, from: encode(shape)) == shape)
  }

  @Test func `a collection of macro-derived elements round-trips`() throws {
    let points = [Point(x: 1, y: 1, label: "a"),
                  Point(x: 2, y: 2, label: "bb"),
                  Point(x: 3, y: 3, label: "ccc")]
    #expect(try decode(Array<Point>.self, from: encode(points)) == points)
  }

  @Test func `an empty collection round-trips`() throws {
    let points: Array<Point> = []
    #expect(try decode(Array<Point>.self, from: encode(points)) == points)
  }

  @Test func `signed integers survive the ZigZag varint`() throws {
    for value in [Int32.min, -1, 0, 1, Int32.max] {
      #expect(try decode(Int32.self, from: encode(value)) == value)
    }
  }

  @Test func `a truncated buffer throws rather than crashing`() throws {
    let bytes = try encode(Point(x: 1, y: 2, label: "z"))
    #expect(throws: DecantError.self) {
      _ = try decode(Point.self, from: Array(bytes.dropLast(3)))
    }
  }
}

// MARK: - Varint encoding

struct VarintTests {
  @Test func `a small unsigned value is a single byte`() throws {
    #expect(try encode(UInt64(1)) == [0x01])
    #expect(try encode(UInt64(127)) == [0x7f])
  }

  @Test func `a value above 127 spills into a continuation byte`() throws {
    #expect(try encode(UInt64(128)) == [0x80, 0x01])
    #expect(try encode(UInt64(300)) == [0xac, 0x02])
  }

  @Test func `unsigned values across the width round-trip`() throws {
    for value in [UInt64.min, 1, 128, 16_384, UInt64.max] {
      #expect(try decode(UInt64.self, from: encode(value)) == value)
    }
  }
}
