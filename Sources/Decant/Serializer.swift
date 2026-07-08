// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Writes the primitive shapes of a value — booleans, integers, strings,
/// sequences, structures — to a byte format.
///
/// A serializer is one half of a two-part decoupling: a `Serializable` type
/// describes its own shape by calling these methods, and a `Serializer`
/// interprets that shape as bytes; neither knows the other, so the compiler
/// pairs any type with any format with no glue between them.
///
/// The methods write straight to the underlying byte sink — no intermediate
/// value tree is ever built — so a value's structure IS the traversal: a single
/// streaming pass with no per-node allocation. A compound value is written in
/// three phases through a sub-serializer: open it, write each child, then close
/// it.
///
/// Every method is `@inlinable` so a caller in another module specializes the
/// whole write tree to straight-line code; without it the write funnels through
/// witness-table dispatch and runs measurably slower.
public protocol Serializer: ~Copyable, ~Escapable {
  /// The error this serializer raises, carried concretely by typed throws.
  associatedtype Failure: Error

  /// The sub-serializer that writes a sequence element by element.
  associatedtype Sequences: SequenceSerializer & ~Copyable & ~Escapable
      where Sequences.Failure == Failure, Sequences.Parent == Self

  /// The sub-serializer that writes a structure field by field.
  associatedtype Structures: StructureSerializer & ~Copyable & ~Escapable
      where Structures.Failure == Failure, Structures.Parent == Self

  /// Writes a boolean.
  @inlinable
  mutating func serialize(_ value: Bool) throws(Failure)

  /// Writes a fixed-width integer of any width.
  @inlinable
  mutating func serialize<T: FixedWidthInteger>(_ value: T) throws(Failure)

  /// Writes a double-precision floating-point value.
  @inlinable
  mutating func serialize(_ value: Double) throws(Failure)

  /// Writes a string.
  @inlinable
  mutating func serialize(_ value: String) throws(Failure)

  /// Writes a run of raw bytes.
  @inlinable
  mutating func serialize(bytes: some Sequence<UInt8>) throws(Failure)

  /// Writes the absence of a value.
  @inlinable
  mutating func null() throws(Failure)

  /// Writes the marker that a wrapped value is present, so the read side can
  /// tell a present value from an absent one before the value itself.
  @inlinable
  mutating func some() throws(Failure)

  /// Opens a sequence of `count` elements (nil if the length is not known),
  /// consuming the serializer and returning the sub-serializer the caller
  /// drives once per element; the sub-serializer's `end` hands the serializer
  /// back.
  ///
  /// Non-throwing so the consume is total: were it to throw, the consumed
  /// serializer could not be restored to the caller's slot. Any framing bytes a
  /// fixed-capacity sink might reject are deferred to the first `element` or to
  /// `end`, which do throw.
  @inlinable
  @_lifetime(copy self)
  consuming func sequence(count: Int?) -> Sequences

  /// Opens a structure named `name` with `count` fields, consuming the
  /// serializer and returning the sub-serializer the caller drives once per
  /// field; the sub-serializer's `end` hands the serializer back. Non-throwing
  /// for the same reason as `sequence`.
  @inlinable
  @_lifetime(copy self)
  consuming func structure(_ name: StaticString, fields count: Int)
      -> Structures
}

/// The sub-serializer that writes a sequence: `element` once per child, then
/// `end`.
///
/// Each `element` writes straight to the sink, so a sequence streams with no
/// buffering. `end` is `consuming`, closing the sequence exactly once.
public protocol SequenceSerializer: ~Copyable, ~Escapable {
  /// The error this serializer raises, matching its parent serializer.
  associatedtype Failure: Error

  /// The serializer this sub-serializer returns to the caller when the
  /// sequence ends.
  associatedtype Parent: Serializer & ~Copyable & ~Escapable
      where Parent.Failure == Failure

  /// Writes one element, recursing into its `Serializable` conformance.
  @inlinable
  mutating func element<T: Serializable>(_ value: borrowing T) throws(Failure)

  /// Closes the sequence and returns the parent serializer so the caller can
  /// keep writing — the `~Copyable` hand-back in place of an `inout` slot.
  @inlinable
  @_lifetime(copy self)
  consuming func end() throws(Failure) -> Parent
}

/// The sub-serializer that writes a structure: `field` once per stored property
/// in declaration order, then `end`.
public protocol StructureSerializer: ~Copyable, ~Escapable {
  /// The error this serializer raises, matching its parent serializer.
  associatedtype Failure: Error

  /// The serializer this sub-serializer returns to the caller when the
  /// structure ends.
  associatedtype Parent: Serializer & ~Copyable & ~Escapable
      where Parent.Failure == Failure

  /// Writes one named field, recursing into its `Serializable` conformance.
  @inlinable
  mutating func field<T: Serializable>(_ name: StaticString,
                                       _ value: borrowing T) throws(Failure)

  /// Closes the structure and returns the parent serializer so the caller can
  /// keep writing — the `~Copyable` hand-back in place of an `inout` slot.
  @inlinable
  @_lifetime(copy self)
  consuming func end() throws(Failure) -> Parent
}

/// A type that can describe its own shape to a `Serializer`, written once
/// against the abstract shape vocabulary regardless of the byte format.
///
/// A conformance calls exactly the methods that describe its shape and knows
/// nothing of any concrete format; the `@Serializable` macro generates one for
/// a struct (a `field` per stored property in declaration order).
public protocol Serializable {
  /// Drives `serializer` to write `self`, consuming it and returning it so the
  /// caller can keep writing. Generic over the format so no existential appears
  /// on the write path; the serializer is `~Copyable` because it owns the byte
  /// sink, and it is threaded by consume/return rather than `inout` so a throw
  /// on a compound path never leaves a half-consumed slot.
  @inlinable
  func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable
}
