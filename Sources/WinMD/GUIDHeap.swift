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
    UUID(uuid: data.withUnsafeBytes {
      $0.load(fromByteOffset: MemoryLayout<uuid_t>.stride * (index - 1), as: uuid_t.self)
    })
  }
}

