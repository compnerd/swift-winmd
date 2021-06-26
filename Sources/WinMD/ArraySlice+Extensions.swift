// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension ArraySlice where Element == UInt8 {
  internal subscript<T>(_ offset: Self.Index, _ as: T.Type = T.self) -> T {
    let begin: Self.Index = self.index(self.startIndex, offsetBy: offset)
    let end: Self.Index = self.index(begin, offsetBy: MemoryLayout<T>.stride)

    return self[begin ..< end].withContiguousStorageIfAvailable {
       UnsafeRawBufferPointer($0).bindMemory(to: T.self)[0]
    } ?? Array(self[begin ..< end]).withUnsafeBufferPointer {
      UnsafeRawBufferPointer($0).bindMemory(to: T.self)[0]
    }
  }
}
