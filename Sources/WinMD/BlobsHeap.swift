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

  /// Opens the blob at `offset`, validating its length prefix and extent, so a
  /// malformed entry throws `.BadImageFormat` rather than trapping.
  ///
  /// The lead byte of the compressed length prefix selects its width:
  /// `0x00..0x7f` is 1 byte, `0x80..0xbf` 2 bytes, `0xc0..0xdf` 4 bytes;
  /// `0xe0` and above is not a defined encoding. The prefix must fit the heap,
  /// and the payload it delimits must not run past the heap end. This mirrors
  /// `SignatureDecoder.width`, which guards the shared `RawSpan.compressed` the
  /// same way.
  @_lifetime(copy self)
  public func blob(at offset: Int) throws(WinMDError) -> Blob {
    guard offset >= 0, offset < bytes.byteCount else { throw .BadImageFormat }
    let width = switch bytes.read(at: offset, as: UInt8.self) {
    case 0x00 ... 0x7f: 1
    case 0x80 ... 0xbf: 2
    case 0xc0 ... 0xdf: 4
    default:            throw .BadImageFormat
    }
    guard offset + width <= bytes.byteCount else { throw .BadImageFormat }
    let (begin, length) = bytes.compressed(at: offset)
    guard length >= 0, begin + length <= bytes.byteCount else {
      throw .BadImageFormat
    }
    return Blob(bytes.extracting(begin ..< begin + length))
  }
}
