// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A blob: a borrowed view over a span of bytes in the "Blobs" heap.
public struct Blob: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan) {
    self.bytes = bytes
  }

  /// The number of bytes in the blob.
  public var count: Int {
    bytes.byteCount
  }

  /// Reads a value from the blob at a byte offset.
  public func load<T: BitwiseCopyable>(at offset: Int,
                                       as _: T.Type = T.self) -> T {
    bytes.read(at: offset, as: T.self)
  }
}

/// Conveiniece wrapper for the "Blobs" heap.
///
/// Allows for easy access into the contents of the "Blobs" heap.
public struct BlobsHeap: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) {
    self.bytes = bytes
  }

  public subscript(offset: Int) -> Blob {
    @_lifetime(copy self)
    get {
      let begin: Int
      let length: Int

      switch bytes.read(at: offset, as: UInt8.self) & 0xE0 {
      case 0x00:
        length = Int(bytes.read(at: offset, as: UInt8.self) & 0x1f)
        begin = offset + 1

      case 0x40:
        let x = bytes.read(at: offset + 1, as: UInt8.self)
        length = Int(bytes.read(at: offset, as: UInt8.self) & 0x1f) << 8
               + Int(x)
        begin = offset + 2

      case 0xc0:
        let x = bytes.read(at: offset + 1, as: UInt8.self)
        let y = bytes.read(at: offset + 2, as: UInt8.self)
        let z = bytes.read(at: offset + 3, as: UInt8.self)
        length = Int(bytes.read(at: offset, as: UInt8.self) & 0x1f) << 24
               + Int(x) << 24
               + Int(y) << 16
               + Int(z)
        begin = offset + 4

      default:
        fatalError("invalid blob size")
      }

      return Blob(bytes.extracting(begin ..< begin + length))
    }
  }
}
