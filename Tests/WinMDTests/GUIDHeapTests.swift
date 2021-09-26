// Copyright (c) 2021 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3

import XCTest
@testable import WinMD

final class GUIDHeapTests: XCTestCase {
  static let heap: [UInt8] = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
  ]

  func testSubscript() {
    let guids = GUIDHeap(data: GUIDHeapTests.heap[...])
    XCTAssertThrowsError(try guids[0]) { error in
      XCTAssertEqual(error as? WinMDError, .InvalidIndex)
    }
    XCTAssertEqual(try guids[1],
                   UUID(uuid: (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f)))
  }
}
