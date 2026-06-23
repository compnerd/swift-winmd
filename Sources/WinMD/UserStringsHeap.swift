// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Convenience wrapper for the "User Strings" (`#US`) heap.
///
/// Allows for easy access into the contents of the `#US` heap.  Each entry is
/// laid out exactly like a blob (ECMA-335 §II.24.2.4): a compressed unsigned
/// integer length prefix followed by that many payload bytes.  For an entry of
/// payload length `L`, the final payload byte is a terminal flag indicating
/// whether any code unit has non-ASCII bits (ignored for the decoded value) and
/// the preceding `L - 1` bytes are the string's UTF-16, little-endian code
/// units.  A length of `0` denotes the empty string at offset `0`.
public struct UserStringsHeap: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    self.bytes = bytes
  }

  public subscript(offset: Int) -> String {
    let (begin, length) = bytes.compressed(at: offset)

    // A length of zero — or one, which leaves only the terminal byte — has no
    // code units and decodes to the empty string.
    guard length > 1 else { return "" }

    // The final payload byte is the terminal flag; the preceding `length - 1`
    // bytes are `(length - 1) / 2` UTF-16 little-endian code units.  `begin`
    // sits past a compressed prefix, so the code-unit range can start at an odd
    // byte offset; extract it as a single raw range and decode it through
    // unaligned, little-endian `UInt16` loads — without materialising the code
    // units in an array.
    let count = (length - 1) / 2
    return bytes.extracting(begin ..< begin + count * 2).withUnsafeBytes { buffer in
      String(decoding: stride(from: 0, to: count * 2, by: 2).lazy.map {
        UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt16.self))
      }, as: UTF16.self)
    }
  }
}
