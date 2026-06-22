// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Convenience wrapper for the "Strings" heap.
///
/// Allows for easy access into the contents of the "Strings" heap.
public struct StringsHeap: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    self.bytes = bytes
  }

  public subscript(offset: Int) -> String {
    // The strings are stored as null-terminated UTF-8 sequences.
    var end = offset
    while end < bytes.byteCount,
        bytes.read(at: end, as: UInt8.self) != 0 {
      end += 1
    }
    return String(decoding: bytes.extracting(offset ..< end), as: UTF8.self)
  }
}
