// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal struct StringsHeap {
  let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public subscript(offset: Int) -> String {
    let index = data.index(data.startIndex, offsetBy: offset)
    return data[index...].withUnsafeBytes {
      String(decodingCString: $0.baseAddress!.assumingMemoryBound(to: UTF8.CodeUnit.self),
             as: UTF8.self)
    }
  }
}
