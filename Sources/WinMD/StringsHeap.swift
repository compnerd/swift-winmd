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

  /// Opens the null-terminated UTF-8 string at `offset`, validating its bounds
  /// and terminator, so a malformed entry throws `.BadImageFormat` rather than
  /// trapping.
  public func string(at offset: Int) throws(WinMDError) -> String {
    guard offset >= 0, offset < bytes.byteCount else { throw .BadImageFormat }
    var end = offset
    while end < bytes.byteCount,
        bytes.read(at: end, as: UInt8.self) != 0 {
      end += 1
    }
    guard end < bytes.byteCount else { throw .BadImageFormat }
    return String(decoding: bytes.extracting(offset ..< end), as: UTF8.self)
  }
}
