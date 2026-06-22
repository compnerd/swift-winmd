// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension ArraySlice where Element == UInt8 {
  internal subscript<T: BitwiseCopyable>(_ offset: Self.Index,
                                         _ as: T.Type = T.self) -> T {
    // `ArraySlice` is always contiguously stored, so `withUnsafeBytes` never
    // needs a fallback copy.  The metadata fields are packed and therefore
    // unaligned, so the value must be read with an unaligned load.
    let begin = index(startIndex, offsetBy: offset)
    return self[begin...].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
  }
}
