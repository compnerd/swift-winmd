// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID

import Testing
@testable import WinMD

struct GUIDHeapTests {
  static let heap: Array<UInt8> = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
  ]

  @Test("reads a GUID by 1-based index and rejects index 0")
  func subscriptAccess() throws {
    let guids = GUIDHeap(data: GUIDHeapTests.heap[...])
    #expect(throws: WinMDError.InvalidIndex) {
      try guids[0]
    }
    #expect(try guids[1] ==
        UUID(uuid: (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f)))
  }
}
