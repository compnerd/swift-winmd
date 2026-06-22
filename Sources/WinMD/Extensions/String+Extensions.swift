// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension String {
  /// Decodes a borrowed byte span as a string in the given encoding.
  init<Encoding: Unicode.Encoding>(decoding span: RawSpan, as encoding: Encoding.Type)
      where Encoding.CodeUnit == UInt8 {
    self = span.withUnsafeBytes { String(decoding: $0, as: encoding) }
  }
}
