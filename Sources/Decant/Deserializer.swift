// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Reads the primitive shapes of a value — booleans, integers, strings,
/// sequences, structures — back from a byte format.
///
/// A deserializer is the read counterpart of `Serializer`: the TYPE names the
/// shape to expect and the deserializer reads exactly that at the cursor. That
/// type-driven order is what lets a non-self-describing format be read at all —
/// a layout that carries no tags relies entirely on the type to dictate every
/// read — and a self-describing format simply ignores the structure it does not
/// need.
///
/// A deserializer owns the read cursor: it holds a borrowed view of the input
/// and a mutating position, reads a value, and advances. Because it borrows the
/// input it is `~Escapable`; because it is threaded through a recursive read
/// without copies it is `~Copyable` and passed `inout`. It copies OUT owned
/// values (an `Int`, a decoded struct) as it walks and never vends a borrowed
/// view that outlives a step.
///
/// Every method is `@inlinable` so a caller in another module specializes the
/// whole read tree to straight-line code.
public protocol Deserializer: ~Copyable, ~Escapable {
  /// The error this deserializer raises, carried concretely by typed throws.
  associatedtype Failure: Error

  /// Reads a fixed-width integer of the requested width — the caller names the
  /// width the type dictates.
  @inlinable
  mutating func integer<T: FixedWidthInteger>(_: T.Type) throws(Failure) -> T

  /// Reads a boolean.
  @inlinable
  mutating func bool() throws(Failure) -> Bool

  /// Reads a double-precision floating-point value.
  @inlinable
  mutating func double() throws(Failure) -> Double

  /// Reads a string.
  @inlinable
  mutating func string() throws(Failure) -> String

  /// Reads a run of raw bytes as an owned array.
  @inlinable
  mutating func bytes() throws(Failure) -> Array<UInt8>

  /// Reads whether the next value is present: true if a value follows, false
  /// for the absent case.
  @inlinable
  mutating func some() throws(Failure) -> Bool

  /// Reads a sequence's element count, so the caller can pull exactly that many
  /// elements with `decode`.
  @inlinable
  mutating func count() throws(Failure) -> Int

  /// Begins reading a structure named `name` with `count` fields. The caller
  /// then reads each field in declaration order with `decode`. The name and
  /// count are the type's hint, not read from the input.
  @inlinable
  mutating func structure(_ name: StaticString, fields count: Int)
      throws(Failure)

  /// Ends reading a structure begun with `structure(_:fields:)`.
  @inlinable
  mutating func end() throws(Failure)
}

extension Deserializer where Self: ~Copyable & ~Escapable {
  /// Reads one value of a `Deserializable` type, recursing into its
  /// conformance — the generic entry point every compound read pulls through.
  /// `@inlinable` so it specializes across the module boundary.
  @inlinable
  public mutating func decode<T: Deserializable>(_: T.Type = T.self)
      throws(Failure) -> T {
    try T.deserialize(from: &self)
  }
}

/// A type that can read itself back from a `Deserializer`, written once against
/// the abstract shape vocabulary regardless of the byte format.
///
/// A conformance calls exactly the methods that describe its shape and returns
/// an owned value copied out of the borrow. The `@Deserializable` macro
/// generates one for a struct (one field read per stored property in
/// declaration order, matching the write side).
public protocol Deserializable {
  /// Reads `Self` from the deserializer. Generic over the format so no
  /// existential appears — which is also forced, since a `~Escapable`
  /// deserializer has none.
  @inlinable
  static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Self
      where D: Deserializer & ~Copyable & ~Escapable
}
