// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// A `Deserializer` that reads the compact binary encoding `BinarySerializer`
/// writes.
///
/// It is a cursor over a borrowed `RawSpan` of the input and a mutating
/// position: it reads a value at the cursor and advances, copying owned values
/// out as it walks. Because it borrows the input it is `~Escapable` — no copy
/// of the input is made — and because it is threaded through a recursive read
/// it is `~Copyable` and passed `inout`. The encoding carries no tags, so each
/// read is driven by the type that asks for it. Every method is `@inlinable` so
/// a cross-module caller specializes the whole decode tree.
public struct BinaryDeserializer: ~Escapable, ~Copyable {
  public typealias Failure = DecantError

  /// The input bytes, borrowed for the deserializer's lifetime.
  @usableFromInline
  internal let input: RawSpan

  /// The read cursor into `input`.
  @usableFromInline
  internal var position: Int

  /// Wraps a borrowed span, positioned at its start.
  @inlinable
  @_lifetime(copy input)
  public init(_ input: RawSpan) {
    self.input = input
    position = 0
  }

  /// Reads one byte, advancing the cursor; throws `.truncated` at the end.
  @inlinable
  internal mutating func byte() throws(DecantError) -> UInt8 {
    guard position < input.byteCount else { throw .truncated }
    defer { position += 1 }
    return input.load(fromByteOffset: position, as: UInt8.self)
  }

  /// Reads an unsigned LEB128 varint.
  @inlinable
  internal mutating func varint() throws(DecantError) -> UInt64 {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while true {
      let byte = try byte()
      result |= UInt64(byte & 0x7f) << shift
      if byte & 0x80 == 0 {
        return result
      }
      shift += 7
    }
  }
}

// MARK: - Deserializer conformance

extension BinaryDeserializer: Deserializer {
  @inlinable
  public mutating func integer<T: FixedWidthInteger>(_: T.Type)
      throws(DecantError) -> T {
    let raw = try varint()
    return if T.isSigned {
      T(truncatingIfNeeded: unzigzag(raw))
    } else {
      T(truncatingIfNeeded: raw)
    }
  }

  @inlinable
  public mutating func bool() throws(DecantError) -> Bool {
    try byte() != 0
  }

  @inlinable
  public mutating func double() throws(DecantError) -> Double {
    Double(bitPattern: try varint())
  }

  @inlinable
  public mutating func string() throws(DecantError) -> String {
    String(decoding: try bytes(), as: UTF8.self)
  }

  @inlinable
  public mutating func bytes() throws(DecantError) -> Array<UInt8> {
    let count = Int(try varint())
    guard position + count <= input.byteCount else { throw .truncated }
    defer { position += count }
    let slice = input.extracting(position ..< position + count)
    return Array<UInt8>(capacity: count) { output in
      for offset in 0 ..< count {
        output.append(slice.load(fromByteOffset: offset, as: UInt8.self))
      }
    }
  }

  @inlinable
  public mutating func some() throws(DecantError) -> Bool {
    try byte() != 0
  }

  @inlinable
  public mutating func count() throws(DecantError) -> Int {
    Int(try varint())
  }

  @inlinable
  public mutating func structure(_ name: StaticString, fields count: Int)
      throws(DecantError) {}

  @inlinable
  public mutating func end() throws(DecantError) {}
}
