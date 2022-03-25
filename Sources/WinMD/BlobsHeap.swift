// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Conveiniece wrapper for the "Blobs" heap.
///
/// Allows for easy access into the contents of the "Blobs" heap.
public struct BlobsHeap {
  let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init(from assembly: Assembly) throws {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.Blob) else {
      throw WinMDError.BlobsHeapNotFound
    }
    self.init(data: stream)
  }

  public subscript(offset: Int) -> ArraySlice<UInt8> {
    let begin: ArraySlice<UInt8>.Index
    let end: ArraySlice<UInt8>.Index

    switch self.data[offset, UInt8.self] & 0xE0 {
    case 0x00:
      let length: Int = Int(self.data[offset, UInt8.self] & 0x1f)

      begin = self.data.index(self.data.startIndex, offsetBy: offset + 1)
      end = self.data.index(begin, offsetBy: length)

    case 0x40:
      let x: UInt8 = self.data[self.data.index(offset, offsetBy: 1), UInt8.self]
      let length: Int = Int(self.data[offset, UInt8.self] & 0x1f) << 8
                      + Int(x)

      begin = self.data.index(self.data.startIndex, offsetBy: offset + 2)
      end = self.data.index(begin, offsetBy: length)

    case 0xc0:
      let x: UInt8 = self.data[self.data.index(offset, offsetBy: 1), UInt8.self]
      let y: UInt8 = self.data[self.data.index(offset, offsetBy: 2), UInt8.self]
      let z: UInt8 = self.data[self.data.index(offset, offsetBy: 3), UInt8.self]
      let length: Int = Int(self.data[offset, UInt8.self] & 0x1f) << 24
                      + Int(x) << 24
                      + Int(y) << 16
                      + Int(z)

      begin = self.data.index(self.data.startIndex, offsetBy: offset + 4)
      end = self.data.index(begin, offsetBy: length)

    default:
      fatalError("invalid blob size")
    }

    return self.data[begin ..< end]
  }
}
