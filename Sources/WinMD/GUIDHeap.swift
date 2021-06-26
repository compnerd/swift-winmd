// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID
import typealias Foundation.uuid_t

internal struct GUIDHeap {
  let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init?(from assembly: Assembly) {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.GUID) else {
      return nil
    }
    self.init(data: stream)
  }

  public subscript(index: Int) -> UUID {
    UUID(uuid: data.withUnsafeBytes {
      $0.load(fromByteOffset: MemoryLayout<uuid_t>.stride * (index - 1), as: uuid_t.self)
    })
  }
}

