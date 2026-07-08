// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Decant

/// The variable-length integer primitives the binary serializer and
/// deserializer share.
///
/// An unsigned value is written as an LEB128 varint: seven payload bits per
/// byte, low group first, with the high bit of each byte set while more bytes
/// follow. A signed value is first folded onto an unsigned one with ZigZag so a
/// small-magnitude negative stays short rather than sign-extending to the full
/// width.

/// Writes `value` to `sink` as an unsigned LEB128 varint.
@inlinable
internal func varint<S: Sink>(_ value: UInt64, into sink: inout S)
    throws(DecantError) {
  var remaining = value
  repeat {
    var byte = UInt8(remaining & 0x7f)
    remaining >>= 7
    if remaining != 0 {
      byte |= 0x80
    }
    try sink.append(byte)
  } while remaining != 0
}

/// Folds a signed value onto an unsigned one so small-magnitude negatives stay
/// short under the varint encoding.
@inlinable
internal func zigzag(_ value: Int64) -> UInt64 {
  UInt64(bitPattern: (value << 1) ^ (value >> 63))
}

/// Inverts `zigzag`.
@inlinable
internal func unzigzag(_ value: UInt64) -> Int64 {
  Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
}
