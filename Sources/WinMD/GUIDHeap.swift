/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

internal struct GUIDHeap {
  let data: Data

  public init(data: Data) {
    self.data = data
  }

  public subscript(index: Int) -> UUID {
    let index = data.index(data.startIndex, offsetBy: 16 * (index - 1))
    return data[index...].withUnsafeBytes {
      UUID(uuid: $0.baseAddress!.assumingMemoryBound(to: uuid_t.self).pointee)
    }
  }
}

