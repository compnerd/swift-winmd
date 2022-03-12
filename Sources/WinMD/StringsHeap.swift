// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Convenience wrapper for the "Strings" heap.
///
/// Allows for easy access into the contents of the "Strings" heap.
public struct StringsHeap {
  let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init?(from assembly: Assembly) {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.Strings) else {
      return nil
    }
    self.init(data: stream)
  }

  public subscript(offset: Int) -> String {
    let index = data.index(data.startIndex, offsetBy: offset)
    return data[index...].withUnsafeBytes {
      String(decodingCString: $0.baseAddress!.assumingMemoryBound(to: UTF8.CodeUnit.self),
             as: UTF8.self)
    }
  }
}
