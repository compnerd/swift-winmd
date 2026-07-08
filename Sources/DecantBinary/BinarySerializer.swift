// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// A `Serializer` that writes a compact, non-self-describing binary encoding.
///
/// Integers are unsigned LEB128 varints; a signed integer rides ZigZag over the
/// same varint; a double is the varint of its bit pattern; a string or a byte
/// run is a varint length prefix then its bytes; a compound value is just its
/// children back to back, since the reading type — not the wire — carries the
/// shape. Nothing on the wire is tagged, so the same type must drive the read.
///
/// The serializer is generic over the `Sink` it owns and threaded by
/// consume/return (the `~Copyable` hand-back in place of `inout`), so a throw
/// on a compound path never leaves a half-consumed slot. Every method is
/// `@inlinable` so a cross-module caller specializes the whole encode tree.
public struct BinarySerializer<Output: Sink>: Serializer, ~Copyable {
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
    try sink.append(value ? 1 : 0)
  }

  @inlinable
  public mutating func serialize<T: FixedWidthInteger>(_ value: T)
      throws(DecantError) {
    if T.isSigned {
      try varint(zigzag(Int64(value)), into: &sink)
    } else {
      try varint(UInt64(value), into: &sink)
    }
  }

  @inlinable
  public mutating func serialize(_ value: Double) throws(DecantError) {
    try varint(value.bitPattern, into: &sink)
  }

  @inlinable
  public mutating func serialize(_ value: String) throws(DecantError) {
    let bytes = Array(value.utf8)
    try varint(UInt64(bytes.count), into: &sink)
    try sink.append(bytes)
  }

  @inlinable
  public mutating func serialize(bytes: some Sequence<UInt8>)
      throws(DecantError) {
    let buffer = Array(bytes)
    try varint(UInt64(buffer.count), into: &sink)
    try sink.append(buffer)
  }

  @inlinable
  public mutating func null() throws(DecantError) {
    try sink.append(0)
  }

  @inlinable
  public mutating func some() throws(DecantError) {
    try sink.append(1)
  }

  @inlinable
  public consuming func sequence(count: Int?)
      -> BinarySequenceSerializer<Output> {
    BinarySequenceSerializer(self, count: count ?? 0)
  }

  @inlinable
  public consuming func structure(_ name: StaticString, fields count: Int)
      -> BinaryStructureSerializer<Output> {
    BinaryStructureSerializer(self)
  }
}

/// The binary sequence sub-serializer: a varint length prefix then a bare run
/// of elements. It owns the parent serializer for the three-phase write and
/// returns it from `end`.
public struct BinarySequenceSerializer<Output: Sink>: SequenceSerializer,
    ~Copyable {
  public typealias Failure = DecantError
  public typealias Parent = BinarySerializer<Output>

  /// The parent serializer, held as `Optional` so it can be moved out (leaving
  /// `.none`, a fully-initialized state) and back — the exception-safe reclaim
  /// across a throwing `element`, since `~Copyable` forbids partially
  /// reinitializing `self` on the throw path.
  @usableFromInline
  internal var serializer: BinarySerializer<Output>?

  /// The element count, written lazily before the first element so `sequence`
  /// can stay non-throwing (the `~Copyable` reclaim requirement).
  @usableFromInline
  internal var pending: UInt64?

  @inlinable
  internal init(_ serializer: consuming BinarySerializer<Output>, count: Int) {
    self.serializer = consume serializer
    pending = UInt64(count)
  }

  @inlinable
  public mutating func element<T: Serializable>(_ value: borrowing T)
      throws(DecantError) {
    var inner = serializer.take()!
    if let count = pending {
      try varint(count, into: &inner.sink)
      pending = nil
    }
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  @inlinable
  public consuming func end() throws(DecantError) -> BinarySerializer<Output> {
    var inner = serializer.take()!
    if let count = pending {
      try varint(count, into: &inner.sink)
    }
    return inner
  }
}

/// The binary structure sub-serializer: fields written back to back, since the
/// reading type carries the shape.
public struct BinaryStructureSerializer<Output: Sink>: StructureSerializer,
    ~Copyable {
  public typealias Failure = DecantError
  public typealias Parent = BinarySerializer<Output>

  /// The parent serializer, held as `Optional` for the same exception-safe
  /// move-out/back reclaim as `BinarySequenceSerializer`.
  @usableFromInline
  internal var serializer: BinarySerializer<Output>?

  @inlinable
  internal init(_ serializer: consuming BinarySerializer<Output>) {
    self.serializer = consume serializer
  }

  @inlinable
  public mutating func field<T: Serializable>(_ name: StaticString,
                                              _ value: borrowing T)
      throws(DecantError) {
    var inner = serializer.take()!
    inner = try value.serialize(into: inner)
    serializer = consume inner
  }

  @inlinable
  public consuming func end() throws(DecantError) -> BinarySerializer<Output> {
    var this = self
    return this.serializer.take()!
  }
}
