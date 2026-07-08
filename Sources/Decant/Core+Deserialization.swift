// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The standard-library `Deserializable` conformances — the leaf deserializers a
/// macro-derived or hand-written struct's fields recurse into.
///
/// Each is `@inlinable`: a struct's generated `decode` bottoms out in, say,
/// `UInt16.deserialize`, and only inlining that leaf across the module boundary
/// keeps the whole aggregate specialized. A non-`@inlinable` leaf here would
/// silently regress every field that touches it to witness-table dispatch.

// MARK: - Bool

extension Bool: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Bool
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.bool()
  }
}

// MARK: - Fixed-width integers

extension FixedWidthInteger where Self: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Self
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.integer(Self.self)
  }
}

extension Int: Deserializable {}
extension Int8: Deserializable {}
extension Int16: Deserializable {}
extension Int32: Deserializable {}
extension Int64: Deserializable {}
extension UInt: Deserializable {}
extension UInt8: Deserializable {}
extension UInt16: Deserializable {}
extension UInt32: Deserializable {}
extension UInt64: Deserializable {}

// MARK: - Floating point

extension Double: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Double
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.double()
  }
}

// MARK: - String

extension String: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> String
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.string()
  }
}

// MARK: - Optional

extension Optional: Deserializable where Wrapped: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Wrapped?
      where D: Deserializer & ~Copyable & ~Escapable {
    guard try deserializer.some() else { return nil }
    return try deserializer.decode(Wrapped.self)
  }
}

// MARK: - Array

extension Array: Deserializable where Element: Deserializable {
  @inlinable
  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Array<Element>
      where D: Deserializer & ~Copyable & ~Escapable {
    let count = try deserializer.count()
    var elements = Array<Element>()
    elements.reserveCapacity(count)
    for _ in 0 ..< count {
      try elements.append(deserializer.decode(Element.self))
    }
    return elements
  }
}
