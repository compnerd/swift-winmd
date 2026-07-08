// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The error a JSON read or write raises — one concrete type carried by typed
/// throws through the whole generic driver stack.
///
/// JSON is a text grammar, so its faults are about the text at a scan position:
/// an unexpected byte, a malformed escape, a lone surrogate, a number that will
/// not parse. Those are a poor fit for the core's shape-level error, so the
/// JSON layer raises its own type and keeps the message a caller sees about the
/// text. It stays a single concrete type so the error travels the generic stack
/// without ever being boxed as an `any Error`.
public enum JSONError: Error, Sendable {
  /// A byte that no production allows appeared where a value, a structural
  /// token, or the end of input was expected. `offset` is its index in the
  /// input; `expected` names what the grammar wanted there.
  case unexpected(UInt8, offset: Int, expected: StaticString)
  /// The input ended while a value or a closing token was still required.
  case truncated
  /// A `\` escape names no valid sequence, or a `\u` sequence is not four hex
  /// digits. `offset` is the index of the offending byte.
  case escape(offset: Int)
  /// A `\uD800`–`\uDFFF` high surrogate was not followed by a matching low
  /// surrogate (or a low surrogate stood alone) — the pair does not decode to a
  /// scalar. `offset` is the index of the offending escape.
  case surrogate(offset: Int)
  /// A numeric literal does not parse as the requested Swift type — out of
  /// range for the integer width, or malformed for a double.
  case number(offset: Int)
  /// The type asked for one kind of value but the input, at this position,
  /// spells another (an object where a number was wanted, a string for a bool).
  case mismatch(expected: StaticString, offset: Int)
  /// Bytes remained after a complete top-level value was read.
  case trailing(offset: Int)
  /// A string literal's bytes are not well-formed UTF-8 — JSON text must be
  /// UTF-8. `offset` is near the offending literal.
  case encoding(offset: Int)
}

extension JSONError {
  /// A fallback for a non-`JSONError` surfacing through an untyped (`rethrows`)
  /// stdlib closure boundary — every closure the layer passes such a boundary
  /// only throws `JSONError`, so this is unreachable in practice but keeps the
  /// typed-throws re-cast total.
  @usableFromInline
  internal static var custom: JSONError {
    .unexpected(0, offset: 0, expected: "value")
  }
}

extension JSONError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .unexpected(byte, offset, expected):
      "unexpected byte 0x\(String(byte, radix: 16)) at \(offset), " +
          "expected \(expected)"
    case .truncated:
      "input ended before the value was complete"
    case let .escape(offset):
      "invalid escape sequence at \(offset)"
    case let .surrogate(offset):
      "unpaired UTF-16 surrogate escape at \(offset)"
    case let .number(offset):
      "malformed or out-of-range number at \(offset)"
    case let .mismatch(expected, offset):
      "expected \(expected) at \(offset)"
    case let .trailing(offset):
      "unexpected trailing content at \(offset)"
    case let .encoding(offset):
      "malformed UTF-8 in string near \(offset)"
    }
  }
}
