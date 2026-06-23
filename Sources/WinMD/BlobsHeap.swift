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
      let (begin, length) = bytes.compressed(at: offset)
      return Blob(bytes.extracting(begin ..< begin + length))
    }
  }
}
