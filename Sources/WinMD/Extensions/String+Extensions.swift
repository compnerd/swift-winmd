// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension String {
  /// Decodes a borrowed byte span as a string in the given encoding.
  init<Encoding: Unicode.Encoding>(decoding span: RawSpan, as encoding: Encoding.Type)
      where Encoding.CodeUnit == UInt8 {
    self = span.withUnsafeBytes { String(decoding: $0, as: encoding) }
  }

  /// Decodes a borrowed byte span as a string in the given encoding, failing
  /// on any invalid code-unit sequence rather than substituting the U+FFFD
  /// replacement character.
  internal init?<Encoding: Unicode.Encoding>(validating span: RawSpan,
                                             as encoding: Encoding.Type)
      where Encoding.CodeUnit == UInt8 {
    let value = span.withUnsafeBytes {
      String(validating: $0, as: encoding)
    }
    guard let value else { return nil }
    self = value
  }
}
