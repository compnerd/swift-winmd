// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import struct Foundation.UUID
public import typealias Foundation.uuid_t

public struct GUIDHeap: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    self.bytes = bytes
  }

  public subscript(index: Int) -> UUID {
    get throws(WinMDError) {
      guard index > 0 else { throw .InvalidIndex }
      let offset = MemoryLayout<uuid_t>.stride * (index - 1)
      return UUID(uuid: bytes.read(at: offset, as: uuid_t.self))
    }
  }
}
