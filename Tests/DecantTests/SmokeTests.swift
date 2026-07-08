// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import Decant

// MARK: - A minimal test-only format
//
// A concrete format is NOT part of the shipped `Decant` library — the concrete
// formats live in their own modules. This tiny format exists only so the test
// target can drive a value through the driver surface end to end and confirm it
// round-trips. It is a fixed-width layout: a bool and a byte are one byte each,
// an integer is its little-endian eight-byte value, a string and a byte run are
// a length prefix (eight bytes) then their bytes, an optional is a presence
// byte then the value, and a compound is its children back to back.

private struct TestSerializer<Output: Sink>: Serializer, ~Copyable {
  typealias Failure = DecantError

  var sink: Output

  init(_ sink: consuming Output) {
    self.sink = sink
  }

  consuming func finish() -> Output {
    sink
  }

  mutating func length(_ value: Int) throws(DecantError) {
    try sink.append(withUnsafeBytes(of: UInt64(value).littleEndian) {
      Array($0)
    })
  }

  mutating func serialize(_ value: Bool) throws(DecantError) {
    try sink.append(value ? 1 : 0)
  }

  mutating func serialize<T: FixedWidthInteger>(_ value: T)
      throws(DecantError) {
    let word = Int64(truncatingIfNeeded: value).littleEndian
    try sink.append(withUnsafeBytes(of: word) { Array($0) })
  }

  mutating func serialize(_ value: Double) throws(DecantError) {
    try sink.append(withUnsafeBytes(of: value.bitPattern.littleEndian) {
      Array($0)
    })
  }

  mutating func serialize(_ value: String) throws(DecantError) {
    let bytes = Array(value.utf8)
    try length(bytes.count)
    try sink.append(bytes)
  }

  mutating func serialize(bytes: some Sequence<UInt8>) throws(DecantError) {
    let buffer = Array(bytes)
    try length(buffer.count)
    try sink.append(buffer)
  }

  mutating func null() throws(DecantError) {
    try sink.append(0)
  }

  mutating func some() throws(DecantError) {
    try sink.append(1)
  }

  consuming func sequence(count: Int?) -> TestSequenceSerializer<Output> {
    TestSequenceSerializer(self, count: count ?? 0)
  }

  consuming func structure(_ name: StaticString, fields count: Int)
      -> TestStructureSerializer<Output> {
    TestStructureSerializer(self)
  }
}

private struct TestSequenceSerializer<Output: Sink>: SequenceSerializer,
    ~Copyable {
  typealias Failure = DecantError
  typealias Parent = TestSerializer<Output>

  var serializer: TestSerializer<Output>?
  var pending: Int?

  init(_ serializer: consuming TestSerializer<Output>, count: Int) {
    self.serializer = consume serializer
    pending = count
  }

  mutating func element<T: Serializable>(_ value: borrowing T)
      throws(DecantError) {
    var inner = serializer.take()!
    if let pending {
      try inner.length(pending)
      self.pending = nil
    }
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  consuming func end() throws(DecantError) -> TestSerializer<Output> {
    var inner = serializer.take()!
    if let pending {
      try inner.length(pending)
    }
    return inner
  }
}

private struct TestStructureSerializer<Output: Sink>: StructureSerializer,
    ~Copyable {
  typealias Failure = DecantError
  typealias Parent = TestSerializer<Output>

  var serializer: TestSerializer<Output>?

  init(_ serializer: consuming TestSerializer<Output>) {
    self.serializer = consume serializer
  }

  mutating func field<T: Serializable>(_ name: StaticString,
      _ value: borrowing T) throws(DecantError) {
    var inner = serializer.take()!
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  consuming func end() throws(DecantError) -> TestSerializer<Output> {
    var this = self
    return this.serializer.take()!
  }
}

private struct TestDeserializer: Deserializer {
  typealias Failure = DecantError

  let storage: Array<UInt8>
  var position: Int

  init(_ bytes: Array<UInt8>) {
    storage = bytes
    position = 0
  }

  mutating func take(_ n: Int) throws(DecantError) -> ArraySlice<UInt8> {
    guard position + n <= storage.count else { throw .truncated }
    defer { position += n }
    return storage[position ..< position + n]
  }

  mutating func word() throws(DecantError) -> UInt64 {
    var value: UInt64 = 0
    for (index, byte) in try take(8).enumerated() {
      value |= UInt64(byte) << (8 * index)
    }
    return value
  }

  mutating func integer<T: FixedWidthInteger>(_: T.Type)
      throws(DecantError) -> T {
    T(truncatingIfNeeded: Int64(bitPattern: try word()))
  }

  mutating func bool() throws(DecantError) -> Bool {
    try take(1).first! != 0
  }

  mutating func double() throws(DecantError) -> Double {
    Double(bitPattern: try word())
  }

  mutating func string() throws(DecantError) -> String {
    String(decoding: try bytes(), as: UTF8.self)
  }

  mutating func bytes() throws(DecantError) -> Array<UInt8> {
    let count = Int(try word())
    return Array(try take(count))
  }

  mutating func some() throws(DecantError) -> Bool {
    try take(1).first! != 0
  }

  mutating func count() throws(DecantError) -> Int {
    Int(try word())
  }

  mutating func structure(_ name: StaticString, fields count: Int)
      throws(DecantError) {}

  mutating func end() throws(DecantError) {}
}

private func roundtrip<T: Serializable & Deserializable>(_ value: T)
    throws(DecantError) -> T {
  var serializer = TestSerializer(ArraySink())
  serializer = try value.serialize(into: serializer)
  var deserializer = TestDeserializer(serializer.finish().bytes)
  return try deserializer.decode(T.self)
}

// MARK: - Fixtures

/// A HAND-WRITTEN conformance over the driver surface — confirms the protocols
/// are usable directly, without any derive. The derive sugar layers on this
/// core in its own module, so nothing here reaches for a macro.
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

// MARK: - A borrowed fixed-capacity serializer
//
// The advertised borrowed-buffer output path: a `Sink` over a caller-supplied
// `MutableSpan` that owns no storage of its own, so it is genuinely
// `~Escapable`. A serializer holding one is itself `~Escapable` — which is
// exactly the conformance the serializer surface's `~Escapable` opt-out
// restores. Before it, `BorrowSerializer: Serializer` was rejected because a
// `Serializer` still carried the default `Escapable` requirement.

private struct BufferSink: Sink, ~Copyable, ~Escapable {
  var buffer: MutableSpan<UInt8>
  var count: Int

  @_lifetime(copy buffer)
  init(_ buffer: consuming MutableSpan<UInt8>) {
    self.buffer = buffer
    count = 0
  }

  mutating func append(_ bytes: some Sequence<UInt8>) throws(DecantError) {
    for byte in bytes { try append(byte) }
  }

  mutating func append(_ byte: UInt8) throws(DecantError) {
    guard count < buffer.count else { throw .overflow }
    buffer[count] = byte
    count += 1
  }
}

private struct BorrowSerializer: Serializer, ~Copyable, ~Escapable {
  typealias Failure = DecantError

  var sink: BufferSink

  @_lifetime(copy sink)
  init(_ sink: consuming BufferSink) {
    self.sink = sink
  }

  mutating func serialize(_ value: Bool) throws(DecantError) {
    try sink.append(value ? 1 : 0)
  }

  mutating func serialize<T: FixedWidthInteger>(_ value: T)
      throws(DecantError) {
    try sink.append(UInt8(truncatingIfNeeded: value))
  }

  mutating func serialize(_ value: Double) throws(DecantError) {
    try sink.append(UInt8(truncatingIfNeeded: value.bitPattern))
  }

  mutating func serialize(_ value: String) throws(DecantError) {
    try sink.append(value.utf8)
  }

  mutating func serialize(bytes: some Sequence<UInt8>) throws(DecantError) {
    for byte in bytes { try sink.append(byte) }
  }

  mutating func null() throws(DecantError) {
    try sink.append(0)
  }

  mutating func some() throws(DecantError) {
    try sink.append(1)
  }

  @_lifetime(copy self)
  consuming func sequence(count: Int?) -> BorrowSubSerializer {
    BorrowSubSerializer(self)
  }

  @_lifetime(copy self)
  consuming func structure(_ name: StaticString, fields count: Int)
      -> BorrowSubSerializer {
    BorrowSubSerializer(self)
  }
}

private struct BorrowSubSerializer: SequenceSerializer, StructureSerializer,
    ~Copyable, ~Escapable {
  typealias Failure = DecantError
  typealias Parent = BorrowSerializer

  var serializer: BorrowSerializer?

  @_lifetime(copy serializer)
  init(_ serializer: consuming BorrowSerializer) {
    self.serializer = consume serializer
  }

  mutating func element<T: Serializable>(_ value: borrowing T)
      throws(DecantError) {
    serializer = try value.serialize(into: serializer.take()!)
  }

  mutating func field<T: Serializable>(_ name: StaticString,
                                       _ value: borrowing T)
      throws(DecantError) {
    serializer = try value.serialize(into: serializer.take()!)
  }

  @_lifetime(copy self)
  consuming func end() throws(DecantError) -> BorrowSerializer {
    var this = self
    return this.serializer.take()!
  }
}

/// A compile-time proof that a `~Escapable` serializer — one whose sink borrows
/// a fixed buffer — satisfies `Serializer & ~Copyable & ~Escapable` and so may
/// drive a `Serializable`. That it type-checks is the guarantee the PR
/// restores; the round-trip below then exercises it at run time.
private func serialize<S>(_ value: borrowing Version,
                          into serializer: consuming S)
    throws(S.Failure) -> S
    where S: Serializer & ~Copyable & ~Escapable {
  try value.serialize(into: serializer)
}

// MARK: - Tests

struct SmokeTests {
  @Test func `a hand-written conformance round-trips`() throws {
    let version = Version(major: 6, minor: 4)
    #expect(try roundtrip(version) == version)
  }

  @Test func `a truncated buffer throws rather than crashing`() throws {
    var serializer = TestSerializer(ArraySink())
    serializer = try Version(major: 1, minor: 2).serialize(into: serializer)
    var deserializer =
        TestDeserializer(Array(serializer.finish().bytes.dropLast(3)))
    #expect(throws: DecantError.self) {
      _ = try deserializer.decode(Version.self)
    }
  }

  @Test func `a borrowed fixed-buffer serializer conforms and writes`()
      throws {
    var storage = Array<UInt8>(repeating: 0, count: 8)
    try storage.withUnsafeMutableBufferPointer { raw throws(DecantError) in
      let span = MutableSpan<UInt8>(_unsafeElements: raw)
      let serializer = BorrowSerializer(BufferSink(span))
      _ = try serialize(Version(major: 1, minor: 2), into: serializer)
    }
    // A structure of two `UInt16` fields writes one byte each in this compact
    // format: the low byte of `major` then of `minor`.
    #expect(storage[0] == 1)
    #expect(storage[1] == 2)
  }
}

// MARK: - Sink

struct SinkTests {
  @Test func `the growable ArraySink accumulates appended bytes`() throws {
    var sink = ArraySink()
    try sink.append(0x01)
    try sink.append([0x02, 0x03] as Array<UInt8>)
    try sink.append(CollectionOfOne(0x04))
    #expect(sink.bytes == [0x01, 0x02, 0x03, 0x04])
  }
}
