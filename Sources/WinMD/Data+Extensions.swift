/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

extension Data {
  internal func read<T>(offset: Data.Index) -> T {
    let begin: Data.Index = self.index(self.startIndex, offsetBy: offset)
    let end: Data.Index = self.index(begin, offsetBy: MemoryLayout<T>.stride)
    return Array<T>(unsafeUninitializedCapacity: 1) {
      self.copyBytes(to: $0, from: begin ..< end)
      $1 = 1
    }[0]
  }
}
