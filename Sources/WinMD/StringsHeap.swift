/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

internal struct StringsHeap {
  let data: Data

  public init(data: Data) {
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
