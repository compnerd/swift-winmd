/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

extension Data {
  internal func read<T>(offset: Data.Index, as _: T.Type = T.self) -> T {
    return self.withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) }
  }
  
  internal func read<T>(index: Array<T>.Index, as _: T.Type = T.self) -> T {
    return self.read(offset: index * MemoryLayout<T>.stride)
  }
}
