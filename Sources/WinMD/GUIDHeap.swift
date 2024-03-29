// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID
import typealias Foundation.uuid_t

public struct GUIDHeap {
  let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init(from assembly: Assembly) throws {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.GUID) else {
      throw WinMDError.GUIDHeapNotFound
    }
    self.init(data: stream)
  }

  public subscript(index: Int) -> UUID {
    get throws {
      guard index > 0 else { throw WinMDError.InvalidIndex }
      return UUID(uuid: data.withUnsafeBytes {
        $0.load(fromByteOffset: MemoryLayout<uuid_t>.stride * (index - 1), as: uuid_t.self)
      })
    }
  }
}

