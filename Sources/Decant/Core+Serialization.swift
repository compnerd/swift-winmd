// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The standard-library `Serializable` conformances — the leaf serializers a
/// macro-derived or hand-written struct's fields recurse into.
///
/// Each is `@inlinable`: a struct's generated `field` bottoms out in, say,
/// `UInt16.serialize`, and only inlining that leaf across the module boundary
/// keeps the whole aggregate specialized. A non-`@inlinable` leaf here would
/// silently regress every field that touches it to witness-table dispatch.

// MARK: - Bool

extension Bool: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var serializer = serializer
    try serializer.serialize(self)
    return serializer
  }
}

// MARK: - Fixed-width integers

extension FixedWidthInteger where Self: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var serializer = serializer
    try serializer.serialize(self)
    return serializer
  }
}

extension Int: Serializable {}
extension Int8: Serializable {}
extension Int16: Serializable {}
extension Int32: Serializable {}
extension Int64: Serializable {}
extension UInt: Serializable {}
extension UInt8: Serializable {}
extension UInt16: Serializable {}
extension UInt32: Serializable {}
extension UInt64: Serializable {}

// MARK: - Floating point

extension Double: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var serializer = serializer
    try serializer.serialize(self)
    return serializer
  }
}

// MARK: - String

extension String: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var serializer = serializer
    try serializer.serialize(self)
    return serializer
  }
}

// MARK: - Optional

extension Optional: Serializable where Wrapped: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var serializer = serializer
    switch self {
    case .none:
      try serializer.null()
      return serializer
    case let .some(wrapped):
      try serializer.some()
      return try wrapped.serialize(into: serializer)
    }
  }
}

// MARK: - Array

extension Array: Serializable where Element: Serializable {
  @inlinable
  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var sequence = serializer.sequence(count: count)
    for element in self {
      try sequence.element(element)
    }
    return try sequence.end()
  }
}
