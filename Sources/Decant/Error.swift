// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The error a `Decant` read or write raises — one concrete type carried by
/// typed throws through the whole generic driver stack.
///
/// Because every method is `throws(DecantError)`, the error stays concrete
/// across the generic calls and is never boxed as an `any Error`. A concrete
/// format layered on the core may raise its own error type instead when its
/// vocabulary differs (a text grammar's syntax faults, say); this type covers
/// the shape-level faults the core itself detects.
public enum DecantError: Error, Sendable {
  /// A fault the caller describes directly, for a condition no other case
  /// models. The string is the message.
  case custom(String)
  /// A value of the wrong kind was read: the format found `found` where the
  /// type asked for `expected`.
  case mismatch(expected: StaticString, found: StaticString)
  /// A compound value of the wrong length was read — `count` elements where the
  /// type expected the shape `expected` describes.
  case length(Int, expected: StaticString)
  /// A structure carries a field the type does not know — the string names it.
  case unknown(String)
  /// A structure omits a field the type requires — the string names it.
  case missing(StaticString)
  /// The input ended while a value was still required — a truncated buffer, or
  /// a prefix that promised more bytes than the input holds.
  case truncated
  /// A sink could not accept more bytes — a fixed-capacity buffer overflowed.
  case overflow
}

extension DecantError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .custom(message):
      message
    case let .mismatch(expected, found):
      "expected \(expected) but found \(found)"
    case let .length(count, expected):
      "invalid length \(count), expected \(expected)"
    case let .unknown(name):
      "unknown field '\(name)'"
    case let .missing(name):
      "missing field '\(name)'"
    case .truncated:
      "input ended before the value was complete"
    case .overflow:
      "the sink cannot accept more bytes"
    }
  }
}
