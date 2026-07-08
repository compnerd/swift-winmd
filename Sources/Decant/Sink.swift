// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The byte destination a `Serializer` writes into.
///
/// A serializer is generic over its sink so one write of a value can drive
/// bytes into a caller-provided fixed buffer or into a growable buffer with no
/// change to the value or the format — a self-describing format cannot know its
/// output length in advance, so the destination must be pluggable.
///
/// A `Sink` is `~Escapable` and `~Copyable`: a fixed-capacity conformer is
/// backed by a view over uninitialized capacity, which is itself
/// `~Escapable`/`~Copyable`, so the sink holding one must be too. It is
/// threaded `inout` through the recursive write.
///
/// Every method is `@inlinable` so a caller in another module specializes the
/// append across the format boundary; without it the append regresses to a
/// witness-table call.
public protocol Sink: ~Copyable, ~Escapable {
  /// Appends a contiguous run of bytes to the output. Throws `.overflow` if a
  /// fixed-capacity conformer cannot accept them.
  @inlinable
  mutating func append(_ bytes: some Sequence<UInt8>) throws(DecantError)

  /// Appends one byte to the output. Throws `.overflow` if a fixed-capacity
  /// conformer is full.
  @inlinable
  mutating func append(_ byte: UInt8) throws(DecantError)
}

extension Sink where Self: ~Copyable & ~Escapable {
  /// Appends a single byte through the sequence overload by default; a
  /// conformer with a cheaper single-byte path overrides this.
  @inlinable
  public mutating func append(_ byte: UInt8) throws(DecantError) {
    try append(CollectionOfOne(byte))
  }
}

/// A growable `Sink` backed by a reallocating `Array<UInt8>` — the destination
/// a caller reaches for when the finished bytes must outlive the write.
///
/// It is `Escapable`/`Copyable` (an owned array outlives any borrow), so a
/// caller keeps its `bytes` after the write; a fixed-capacity conformer over a
/// caller-supplied buffer is the alternative when the output length is bounded.
public struct ArraySink: Sink {
  /// The accumulated output bytes; `@usableFromInline` so the `@inlinable`
  /// append methods may mutate it across the module boundary.
  @usableFromInline
  internal var storage: Array<UInt8>

  /// The accumulated output bytes.
  @inlinable
  public var bytes: Array<UInt8> {
    storage
  }

  /// Creates an empty sink, optionally reserving capacity.
  @inlinable
  public init(capacity: Int = 0) {
    storage = Array<UInt8>()
    if capacity > 0 {
      storage.reserveCapacity(capacity)
    }
  }

  @inlinable
  public mutating func append(_ bytes: some Sequence<UInt8>)
      throws(DecantError) {
    storage.append(contentsOf: bytes)
  }

  @inlinable
  public mutating func append(_ byte: UInt8) throws(DecantError) {
    storage.append(byte)
  }
}
