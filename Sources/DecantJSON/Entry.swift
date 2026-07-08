// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// The generic entry points a consumer calls to move a value through JSON — the
/// public verbs, kept generic (never an existential) and `@inlinable` so the
/// whole type-and-format pairing specializes at the call site.

/// Encodes a value to JSON text, returned as a `String`.
///
/// The write side fails only when its `Sink` rejects bytes (a fixed buffer
/// overflowing), which is the core's `DecantError.overflow` — there is no
/// JSON-specific write fault — so it keeps the core error; the parse side,
/// where the syntax faults live, raises `JSONError`.
@inlinable
public func encode<T: Serializable>(json value: borrowing T)
    throws(DecantError) -> String {
  try String(decoding: bytes(json: value), as: UTF8.self)
}

/// Encodes a value to JSON, returned as raw UTF-8 bytes over the growable
/// `ArraySink`.
@inlinable
public func bytes<T: Serializable>(json value: borrowing T)
    throws(DecantError) -> Array<UInt8> {
  var serializer = JSONSerializer(ArraySink())
  serializer = try value.serialize(into: serializer)
  return serializer.finish().bytes
}

/// Decodes a value from JSON UTF-8 bytes, driving the read over a borrowed view
/// of `bytes` so no copy of the input is made. Trailing content after the
/// top-level value is a `.trailing` fault.
@inlinable
public func decode<T: Deserializable>(_: T.Type = T.self,
                                      json bytes: borrowing Array<UInt8>)
    throws(JSONError) -> T {
  let span = bytes.span
  var deserializer = JSONDeserializer(span.bytes)
  let value = try deserializer.decode(T.self)
  try deserializer.close()
  deserializer.scanner.skip()
  if deserializer.scanner.peek() != nil {
    throw JSONError.trailing(offset: deserializer.scanner.offset)
  }
  return value
}

/// Decodes a value from a JSON `String`.
@inlinable
public func decode<T: Deserializable>(_: T.Type = T.self, json text: String)
    throws(JSONError) -> T {
  try decode(T.self, json: Array(text.utf8))
}
